require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'byebug'

class SpotMaker
  def initialize
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @backlog = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-test')
    @wip = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-wip-test')    
    # @backlog = 'render-test'
    # @wip = 'render-wip'
    @s3 = Aws::S3::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    @ec2 = Aws::EC2::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    @ami_id = @ec2.describe_images(filters: [
      { name: 'tag:Name', values: ['RenderSlave-initial'] }]).
        images.first.image_id
    poll
  end

  def run_program
    ratio = birth_ratio
    start_slaves(appropriate_ratio_for_starting(ratio)) if ratio >= 1#0
    poll
  end

  def poll
    poller = Aws::SQS::QueuePoller.new(
      'https://sqs.us-west-2.amazonaws.com/828660616807/backlog')
    poller.poll do |msg|
      byebug
      poller.delete_message(msg) 
      run_program # run_job deletes message after it's finished
    end
  end

  def birth_ratio
    wip = @wip.objects.count.to_f
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count.to_f / wip)
  end

  def appropriate_ratio_for_starting(count)
    ratio = (count / 10.0).floor
    ratio == 0 ? 1 : ratio
  end

  def start_slaves(instance_count)
    byebug
    fleet = @ec2.request_spot_fleet(
      spot_fleet_request_config: slave_fleet_params(instance_count))
    fleet
  end

  def slave_fleet_params(instance_count)
    params = { client_token: "Render Slave: #{SecureRandom.hex}",
    spot_price: '1.00',
    target_capacity: instance_count,
    iam_fleet_role: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
    launch_specifications: slave_fleet_launch_specifications }
  end

  def slave_fleet_launch_specifications
    launch_specifications = []
    available_instance_types.each do |inst_type|
      launch_specifications << {
        image_id: @ami_id,
        # key_name: 'RenderSlave',
        instance_type: inst_type,
        monitoring: { enabled: true },
        # iam_instance_profile: {
        #   arn: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
        #   name: 'render-man_fleet_request'}}
      }
    end
    launch_specifications
  end

  def available_instance_types
    ['m4.large', 'm3.large']
  end
end

SpotMaker.new