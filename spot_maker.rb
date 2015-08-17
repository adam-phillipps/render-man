require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'byebug'

class SpotMaker
  def initialize
    @backlog = 'render-test'
    @wip = 'render-wip'
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @s3 = Aws::S3::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    @ec2 = Aws::EC2::Client.new(
      region: ENV['AWS_REGION'], credentials: creds)
    poll
  end

  def run_program
    ratio = birth_ratio
    start_slaves(appropriate_ratio_for_starting(ratio)) if ratio >= 10
    poll
  end

  def poll
    poller = Aws::SQS::QueuePoller.new(
      'https://sqs.us-west-2.amazonaws.com/828660616807/backlog')
    poller.poll do |msg|     
      run_program # run_job deletes message after it's finished
    end
  end

  def birth_ratio
    byebug
    wip = @s3.list_objects(bucket: 'render-wip').contents.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    @s3.list_objects(bucket: 'render-test').contents.count / wip
  end

  def start_slaves(instance_count)
    @ec2.request_spot_fleet(
      spot_fleet_request_config: slave_fleet_params(instance_count)
  end


  def render_slave_ami
    @ec2.describe_images(filters: {name: 'Name', values: 'RenderSlave'}).
      images.first.image_id
  end

  def map_for_required_options(spot_prices)
    byebug
    spot_prices.each.map(&:spot_price_history).flatten.
      map{ |sph| {
        spot_price: sph.spot_price, 
        availability_zone: sph.availability_zone, 
        instance_type: sph.instance_type} }.
          min_by {|sp| sp[:price]}
  end

  def best_price_and_zone_for(options={})
    spot_prices = []
    @ec2.describe_spot_price_history(
    start_time: (Time.now + 86400).iso8601.to_s,# future date yields current spot prices
    instance_types: [options[:instance_types]],
    product_descriptions: 'Windows'])
    best_match = map_for_required_options(spot_prices)
    best_match[:spot_price] = add_buffer_to_price(best_match[:spot_price])
    best_match
  end

  def add_buffer_to_price(price)
    float_price = price.to_f
    ((float_price + (float_price * 0.2)).round(3)).to_s
  end
  
  def all_zones
    @ec2.describe_availability_zones.
      availability_zones.map(&:zone_name)
  end

  def available_instance_types
    ['t1.micro', 't2.micro', 'm3.large']
  end

  def slave_fleet_params(instance_count)
    best_match_data = best_price_and_zone_for(
      instance_type: available_instance_types,
      product_descriptions: 'Windows'})

    { spot_price: best_match_data[:spot_price],
    target_capacity: instance_count,
    iam_fleet_role: 'render-man_fleet_request', # required
    launch_specifications: spot_fleet_launch_specifications }
  end

  def spot_fleet_launch_specifications
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
    launch_specifications
end

SpotMaker.new