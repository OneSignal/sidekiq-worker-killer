require "get_process_mem"
require "sidekiq"
begin
  require "sidekiq/util"
  SidekiqComponent = Sidekiq::Util
rescue LoadError
  require "sidekiq/middleware/modules"
  SidekiqComponent = Sidekiq::ServerMiddleware
end
require "sidekiq/api"

# Sidekiq server middleware. Kill worker when the RSS memory exceeds limit
# after a given grace time.
class Sidekiq::WorkerKiller
  include SidekiqComponent

  MUTEX = Mutex.new

  # @param [Hash] options
  # @option options [Integer] max_rss
  #   Max RSS in MB. Above this, shutdown will be triggered.
  #   (default: `0` (disabled))
  # @option options [Integer] grace_time
  #   When shutdown is triggered, the Sidekiq process will not accept new job
  #   and wait at most 15 minutes for running jobs to finish.
  #   If Float::INFINITY is specified, will wait forever. (default: `900`)
  # @option options [Integer] shutdown_wait
  #   when the grace time expires, still running jobs get 30 seconds to
  #   stop. After that, kill signal is triggered. (default: `30`)
  # @option options [String] kill_signal
  #   Signal to use to kill Sidekiq process if it doesn't stop.
  #   (default: `"SIGKILL"`)
  # @option options [Boolean] gc
  #   Try to run garbage collection before Sidekiq process stops in case
  #   of exceeded max_rss. (default: `true`)
  # @option options [Proc] skip_shutdown_if
  #   Executes a block of code after max_rss exceeds but before requesting
  #   shutdown. (default: `proc {false}`)
  # @option options [Proc] on_shutdown
  #   Executes a block of code right before a shutdown happens.
  #   (default: `nil`)
  def initialize(options = {})
    @max_rss         = options.fetch(:max_rss, 0)
    @grace_time      = options.fetch(:grace_time, 15 * 60)
    @shutdown_wait   = options.fetch(:shutdown_wait, 30)
    @kill_signal     = options.fetch(:kill_signal, "SIGKILL")
    @gc              = options.fetch(:gc, true)
    @skip_shutdown   = options.fetch(:skip_shutdown_if, proc { false })
    @on_shutdown     = options.fetch(:on_shutdown, nil)
  end

  # @param [String, Class] worker_class
  #   the string or class of the worker class being enqueued
  # @param [Hash] job
  #   the full job payload
  #   @see https://github.com/mperham/sidekiq/wiki/Job-Format
  # @param [String] queue
  #   the name of the queue the job was pulled from
  # @yield the next middleware in the chain or the enqueuing of the job
  def call(worker, job, queue)
    yield
    # Skip if the max RSS is not exceeded
    return unless @max_rss > 0
    return unless current_rss > @max_rss
    GC.start(full_mark: true, immediate_sweep: true) if @gc
    return unless current_rss > @max_rss
    if skip_shutdown?(worker, job, queue)
      warn "current RSS #{current_rss} exceeds maximum RSS #{@max_rss}, " \
           "however shutdown will be ignored"
      return
    end

    warn "current RSS #{current_rss} of #{identity} exceeds " \
         "maximum RSS #{@max_rss}"

    error "Initiating shutdown due to process #{::Process.pid} using RSS=#{current_rss}Mb. The process might get killed in #{@grace_time}s. JID: #{job['jid']}, Job: #{worker.class.name}, Args: #{job['args']}"

    run_shutdown_hook(worker, job, queue)
    request_shutdown(worker, job, queue)
  end

  private

  def run_shutdown_hook(worker, job, queue)
    @on_shutdown.respond_to?(:call) && @on_shutdown.call(worker, job, queue)
  end

  def skip_shutdown?(worker, job, queue)
    @skip_shutdown.respond_to?(:call) && @skip_shutdown.call(worker, job, queue)
  end

  def request_shutdown(worker, job, queue)
    # In another thread to allow underlying job to finish
    Thread.new do
      # Only if another thread is not already
      # shutting down the Sidekiq process
      shutdown(worker, job, queue) if MUTEX.try_lock
    end
  end

  def shutdown(worker, job, _queue)
    warn "sending quiet to #{identity}"
    sidekiq_process.quiet!

    sleep(5) # gives Sidekiq API 5 seconds to update ProcessSet

    warn "shutting down #{identity} in #{@grace_time} seconds"

    finished_gracefully = wait_job_finish_in_grace_time

    error "stopping #{identity}. JID: #{job['jid']}, Job: #{worker.class.name}, Args: #{job['args']}"
    sidekiq_process.stop!

    if finished_gracefully
      warn 'all jobs finished gracefully'
    else
      warn 'grace time exceeded'

      warn "waiting #{@shutdown_wait} seconds before sending " \
             "#{@kill_signal} to #{identity}"
      sleep(@shutdown_wait)

      error "(OOM) Sending #{@kill_signal} to #{::Process.pid}. JID: #{job['jid']}, Job: #{worker.class.name}, Args: #{job['args']}"
      ::Process.kill(@kill_signal, ::Process.pid)
    end
  end

  # Returns true if the job finished within the grace period,
  # false if the grace time was exceeded.
  def wait_job_finish_in_grace_time
    start = Time.now

    while true
      return true if jobs_finished?
      return false if grace_time_exceeded?(start)
      sleep(1)
    end
  end

  def grace_time_exceeded?(start)
    return false if @grace_time == Float::INFINITY

    start + @grace_time < Time.now
  end

  def jobs_finished?
    sidekiq_process.stopping? && sidekiq_process["busy"] == 0
  end

  def current_rss
    ::GetProcessMem.new.mb
  rescue IOError
    # It is possible to get an IOError: stream closed while looking at
    # /proc/{pid}/status. We get this error hundreds of times per day (Sep
    # 2021).  GetProcessMem has another more expensive option to calculate the
    # memory, parsing and summing information in /proc/{pid}/smaps
    b = ::GetProcessMem.new.linux_memory
    (b/::GetProcessMem::MB_TO_BYTE).to_f
  end

  def sidekiq_process
    Sidekiq::ProcessSet.new.find do |process|
      process["identity"] == identity
    end || raise("No sidekiq worker with identity #{identity} found")
  end

  def identity
    config[:identity] || config["identity"]
  end unless method_defined?(:identity)

  def warn(msg)
    Sidekiq.logger.warn(msg)
  end

  def error(msg)
    Sidekiq.logger.error(msg)
  end
end
