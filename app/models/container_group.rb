class ContainerGroup < ApplicationRecord
  acts_as_miq_taggable

  include SupportsFeatureMixin
  include ComplianceMixin
  include CustomAttributeMixin
  include MiqPolicyMixin
  include NewWithTypeStiMixin
  include TenantIdentityMixin
  include ArchivedMixin
  include CustomActionsMixin
  include Purging

  # :name, :uid, :creation_timestamp, :resource_version, :namespace
  # :labels, :restart_policy, :dns_policy

  has_many :containers, :dependent => :destroy
  has_many :container_images, -> { distinct }, :through => :containers
  belongs_to  :ext_management_system, :foreign_key => "ems_id"
  has_many :annotations, -> { where(:section => "annotations") }, # rubocop:disable Rails/HasManyOrHasOneDependent
           :class_name => "CustomAttribute",
           :as         => :resource,
           :inverse_of => :resource
  has_many :labels, -> { where(:section => "labels") }, # rubocop:disable Rails/HasManyOrHasOneDependent
           :class_name => "CustomAttribute",
           :as         => :resource,
           :inverse_of => :resource
  has_many :node_selector_parts, -> { where(:section => "node_selectors") }, # rubocop:disable Rails/HasManyOrHasOneDependent
           :class_name => "CustomAttribute",
           :as         => :resource,
           :inverse_of => :resource
  has_many :container_conditions, :class_name => "ContainerCondition", :as => :container_entity, :dependent => :destroy
  belongs_to :container_node
  has_and_belongs_to_many :container_services, :join_table => :container_groups_container_services
  belongs_to :container_replicator
  belongs_to :container_project
  belongs_to :container_build_pod
  has_many :container_volumes, :as => :parent, :dependent => :destroy
  has_many :persistent_volume_claim, :through => :container_volumes
  has_many :persistent_volumes, -> { where(:type=>'PersistentVolume') }, :through => :persistent_volume_claim, :source => :container_volumes

  # Metrics destroy is handled by purger
  has_many :metrics, :as => :resource
  has_many :metric_rollups, :as => :resource
  has_many :vim_performance_states, :as => :resource
  delegate :my_zone, :to => :ext_management_system, :allow_nil => true

  virtual_column :ready_condition_status, :type => :string, :uses => :container_conditions
  virtual_column :running_containers_summary, :type => :string

  def ready_condition
    if container_conditions.loaded?
      container_conditions.detect { |condition| condition.name == "Ready" }
    else
      container_conditions.find_by(:name => "Ready")
    end
  end

  def ready_condition_status
    ready_condition.try(:status) || 'None'
  end

  def container_states_summary
    containers.group(:state).count.symbolize_keys
  end

  def running_containers_summary
    summary = container_states_summary
    "#{summary[:running] || 0}/#{summary.values.sum}"
  end

  # validates :restart_policy, :inclusion => { :in => %w(always onFailure never) }
  # validates :dns_policy, :inclusion => { :in => %w(ClusterFirst Default) }

  include EventMixin
  include Metric::CiMixin

  def event_where_clause(assoc = :ems_events)
    case assoc.to_sym
    when :ems_events, :event_streams
      # TODO: improve relationship using the id
      ["container_namespace = ? AND container_group_name = ? AND #{events_table_name(assoc)}.ems_id = ?",
       container_project.try(:name), name, ems_id]
    when :policy_events
      # TODO: implement policy events and its relationship
      ["#{events_table_name(assoc)}.ems_id = ?", ems_id]
    end
  end

  def ems_event_filter
    {
      "container_group_name" => name,
      "container_namespace"  => container_project.name,
      "ems_id"               => ext_management_system.id
    }
  end

  def miq_event_filter
    {"ems_id" => ext_management_system.id}
  end

  PERF_ROLLUP_CHILDREN = []

  def perf_rollup_parents(interval_name = nil)
    unless interval_name == 'realtime'
      ([container_project, container_replicator] + container_services).compact
    end
  end

  def disconnect_inv
    return if archived?

    _log.info("Disconnecting Pod [#{name}] id [#{id}] from EMS [#{ext_management_system.name}] id [#{ext_management_system.id}]")
    containers.each(&:disconnect_inv)
    self.container_services = []
    self.container_replicator_id = nil
    self.container_build_pod_id = nil
    self.deleted_on = Time.now.utc
    save
  end

  def self.class_by_ems(ext_management_system)
    ext_management_system&.class_by_ems(:ContainerGroup)
  end

  def self.create_container_pod(ems_id, options = {})
    ems = ExtManagementSystem.find_by(:id => ems_id)
    raise ArgumentError, _("EMS cannot be nil") if ems.nil?

    klass = ems.class_by_ems(:ContainerGroup)
    klass.raw_create_container_pod(ems, options)
  end

  def self.raw_create_container_pod(_ext_management_system, _options = {})
    raise NotImplementedError, _("raw_create_container_pod must be implemented in a subclass")
  end

  def self.create_container_pod_queue(userid, ext_management_system, options = {})
    task_opts = {
      :action => "Creating Container Pod for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => ext_management_system.class_by_ems(:ContainerGroup).name,
      :method_name => 'create_container_pod',
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => [ext_management_system.id, options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def update_container_pod(options = {})
    raw_update_container_pod(options)
  end

  def raw_update_container_pod(_options = {})
    raise NotImplementedError, _("raw_update_container_pod must be implemented in a subclass")
  end

  def update_container_pod_queue(userid, options = {})
    task_opts = {
      :action => "Updating Container Pod for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'update_container_pod',
      :instance_id => id,
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => [options]
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def delete_container_pod
    raw_delete_container_pod
  end

  def delete_container_pod_queue(userid)
    task_opts = {
      :action => "Deleting Container Pod for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => 'delete_container_pod',
      :instance_id => id,
      :role        => 'ems_operations',
      :queue_name  => ext_management_system.queue_name_for_ems_operations,
      :zone        => ext_management_system.my_zone,
      :args        => []
    }

    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def raw_delete_container_pod
    raise NotImplementedError, _("raw_delete_container_pod must be implemented in a subclass")
  end

  def self.display_name(number = 1)
    n_('Pod', 'Pods', number)
  end
end
