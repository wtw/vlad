require 'rubygems'
require 'open4'

require 'vlad'

class Rake::RemoteTask < Rake::Task
  include Open4

  attr_accessor :options, :target_host
  attr_reader :remote_actions

  def initialize(task_name, app)
    super
    @remote_actions = []
  end

  alias_method :original_enhance, :enhance
  def enhance(deps=nil, &block)
    original_enhance(deps)
    @remote_actions << Action.new(self, block) if block_given?
    self
  end

  # -- HERE BE DRAGONS --
  # We are defining singleton methods on the task AS it executes
  # for each 'set' variable. We do this because we need to be support
  # 'application' and similar Rake-reserved names inside remote tasks.
  # This relies on the current (rake 0.7.3) calling conventions.
  # If this breaks blame Jim Weirich and/or society.
  def execute
    raise Vlad::ConfigurationError, "No target hosts specified for task: #{self.name}" if target_hosts.empty?
    super
    Vlad.instance.env.keys.each do |name|
      self.instance_eval "def #{name}; Vlad.instance.fetch('#{name}'); end"
    end
    @remote_actions.each { |act| act.execute(target_hosts) }
  end

  def run command
    command = "sh -c \"#{command}\" 2>&1"
    cmd = ["ssh", target_host, command]

    status = popen4(*cmd) do |pid, inn, out, err|
      inn.sync = true

      until out.eof? and err.eof? do
        reads, = select [out, err], nil, nil, 0.1

        reads.each do |readable|
          data = readable.readpartial(1024)

          inn.puts sudo_password if data =~ /^Password:/
        end
      end
    end

    unless status.success? then
      raise Vlad::CommandFailedError, "execution failed with status #{status.exitstatus}: #{cmd.join ' '}"
    end
  end

  def sudo command
    run "sudo #{command}"
  end

  def target_hosts
    roles = options[:roles]
    roles ? Vlad.instance.hosts_for(roles) : Vlad.instance.all_hosts
  end

  class Action
    attr_reader :task, :block, :workers

    def initialize task, block
      @task  = task
      @block = block
      @workers = []
    end

    def == other
      return false unless Action === other
      block == other.block && task == other.task
    end

    def execute hosts
      hosts.each do |host|
        t = task.clone
        t.target_host = host
        thread = Thread.new(t) do |task|
          task.instance_eval(&block)
        end
        @workers << thread
      end
      @workers.each { |w| w.join }
    end
  end
end