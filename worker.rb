require_relative './render'
require_relative './job'

class Worker
  include Render
  def initialize
    poll
  end


  def boot_time
    @instance_boot_time ||= Time.now.to_i#ec2.describe_instances(instance_ids:[self_id]).reservations[0].instances[0].launch_time
  end

  def poll
    until should_stop? do
      puts 'Polling....'
      sleep rand((571 / 137.0) * 100) / 100
      backlog_poller.poll(
        wait_time_seconds: nil,
        max_number_of_messages: 1,
        visibility_timeout: 30 # keep message invisible long enough to process to wip
      ) do |msg, stats|
        puts 'Polling....'
        # begin
        if JSON.parse(msg.body).has_key?('Records')
          puts "\n\nRunable job found:\n#{JSON.parse(msg.body)}"
          job = Job.new(msg, backlog_address)
          run_job(job)
          puts "finished job:\n #{job.key}\n\n"
        else
          sqs.delete_message({
            queue_url: backlog_address,
            receipt_handle: msg.receipt_handle
          })
        end
      end
    end
    ec2.terminate_instancers(ids: [self_id])
  end

  def should_stop?
    # if you're the last one, (in active state) don't kill yourself
    if hour_mark_approaches?
      death_ratio_acheived? ? true : false
    else
      false
    end
  end

  def hour_mark_approaches?
    ((Time.now.to_i - boot_time) % 3600) > 3300
  end

  def death_ratio_acheived?
    death_ratio >= 10
  end

  def death_ratio
    counts = [finished_address, wip_address].map do |board|
      sqs.get_queue_attributes(
        queue_url: board,
        attribute_names: ['ApproximateNumberOfMessages']
      ).attributes['ApproximateNumberOfMessages'].to_f
    end

    wip = counts[1]
    wip = wip == 0.0 ? 1.0 : wip # guards against dividing by zero
    counts[0] / wip
  end

  def run_job(job)
    if job.board == backlog_address
      job.pull_file_from_backlog
      job.update_status
      job.unzip_file_and_unpack
      job.signal_a_e_to_start
      job.push_file
      job.transcode_from_video_in
      job.clean_up_for_next_job
    else
      puts "*********************************'\n\
        job doesn't exist;  from #run_job:\n#{job.key}"
    end
  end

  def self_id
    'asdfasdf'#@id ||= HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
  end
end

Worker.new