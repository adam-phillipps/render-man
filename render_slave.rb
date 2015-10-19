require 'aws-sdk'
Aws.use_bundled_cert!
require 'dotenv'
Dotenv.load
require 'httparty'
require 'logger'
require 'date'
require 'securerandom'
require 'byebug'

class RenderSlave
  def initialize
    begin
      @file = File.open(File.expand_path('../render_slave.log', __FILE__), 'a+')
      @logger = Logger.new(@file)
      @logger.level = Logger::INFO
      @id = HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
      creds = Aws::Credentials.new(
        ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
      @s3 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @s3_resource = Aws::S3::Resource.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @ec2 = Aws::EC2::Client.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @backlog = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-backlog-test')
      @wip = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-wip-test')
      @finished = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-finished-test')
      @log = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-log')
      boot_time
      @boot_time = Time.now
      @logger.info("******************************\n" +
        "********************************************************************************\n" +
        "RENDERSLAVE #{@id} IS AWAKE\nBOOT TIME: #{@boot_time}\nBEGIN POLLING:\n")
      poll
      @logger.info("Shutting down after polling...")
      s3_log
      sleep 10
      @ec2.stop_instances(instance_ids: [@id])
      #@ec2.terminate_instances(instance_ids: [@id])
    rescue => e
      @logger.fatal('render_slave.rb') { "FATAL ERROR: #{e}" }
      s3_log
    end
  end

  def boot_time
    @boot_time ||= @ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def death_ratio_achieved?
    ratio <= 10.0
  end

  def hour_mark_approaches?
    time_difference = (Time.now.to_i - @boot_time.to_i) % 3600
    @logger.info("instance time used: #{time_difference} (stops at 3301)")
    time_difference > 3300
  end
  
  def job_in_wip?(job)
    begin
      @wip.object(job.key).exists?
    rescue Aws::S3::Errors::NotFound
      false
    end
  end

  def move_to(job,source,target, additional_info = '')
    key = job.key
    @s3.copy_object(
      bucket: target.name,
      copy_source: "#{source.name}/#{key}",
      key: key)
    @s3.delete_object(
      bucket: source.name,
      key: key)
    @logger.info("moving job: #{key}, from: #{source.name} ----> to: #{target.name} " + additional_info)
    target.object key
  end

  def poll
    begin
      until should_stop? do
        sleep rand(571) / 137.0 # offsets polling for other slaves
        job = @backlog.objects.first.object # get the oldest file
        unless job_in_wip?(job)
          job = move_to(job, @backlog, @wip)
          run job
        end
      end
    rescue => e
      @logger.fatal("fatal error in poll: #{e}")
    end
  end

  def ratio
    wip = @wip.objects.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count / wip)
  end

  def run(job)
    unless job.nil?
      start_time = Time.now.to_i
      @logger.info("running job: #{job.key}")
      # run the render job
      sleep 1
      job_run_time = Time.now.to_i - start_time
      additional_info = "-> job took #{job_run_time.to_s} seconds to run and/or fail"
      move_to(job, @wip, @finished, additional_info)
    end
  end

  def s3_log
    log_file = Aws::S3::Object.new(@log.name, "#{@boot_time} --> #{@id}", @s3)
    log_file.upload_file(@file.path)
  end

  def should_stop?
    if hour_mark_approaches?
      @logger.info("Hour mark approaching: #{@boot_time} --> #{DateTime.now}")
      if death_ratio_achieved?
        @logger.info("Death ratio (#{ratio}) achieved")
        true
      else
        false
      end
    else
      false
    end
  end
end

RenderSlave.new