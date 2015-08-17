require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'byebug'

class SpotMaker
  def initialize
    @backlog = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-test')
    @wip = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-wip-test')    
    # @backlog = 'render-test'
    # @wip = 'render-wip'
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @s3 = Aws::S3::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    @ec2 = Aws::EC2::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    poll
  end

  def run_program
    byebug
    ratio = birth_ratio
    start_slaves(appropriate_ratio_for_starting(ratio)) if ratio >= 10
    poll
  end

  def poll
    byebug
    poller = Aws::SQS::QueuePoller.new(
      'https://sqs.us-west-2.amazonaws.com/828660616807/backlog')
    poller.poll do |msg|     
      run_program # run_job deletes message after it's finished
    end
  end

  def birth_ratio
    byebug
    wip = @wip.objects.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count / wip)
    # wip = @s3.list_objects(bucket: 'render-wip').contents.count
    # wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    # @s3.list_objects(bucket: 'render-test').contents.count / wip
  end

  def appropriate_ratio_for_starting(count)
    byebug
    count / 10
  end

  def start_slaves(instance_count)
    byebug
    @ec2.request_spot_fleet(
      spot_fleet_request_config: slave_fleet_params(instance_count)
  end

  def slave_fleet_params(instance_count)
    byebug
    { spot_price: '12.00',
    target_capacity: instance_count,
    iam_fleet_role: 'render-man_fleet_request', # required
    launch_specifications: slave_fleet_launch_specifications }
  end

  def slave_fleet_launch_specifications
    byebug
    launch_specifications = []
    available_instance_types.each do |inst_type|
      launch_specifications << {
        image_id: render_slave_ami,
        key_name: 'RenderSlave',
        instance_type: inst_type,
        monitoring: { enabled: true },
        iam_instance_profile: {
          arn: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
          name: 'render-man_fleet_request'}}
    end
    byebug
    launch_specifications
  end

  def render_slave_ami
    byebug
    @ami ||= @ec2.describe_images(filters: { name: 'Name', values: 'RenderSlave' }).
      images.first.image_id
    byebug
  end

  def available_instance_types
    byebug
    ['t1.micro', 't2.micro', 'm3.large']
  end
end

SpotMaker.new