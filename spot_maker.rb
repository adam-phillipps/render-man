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
    start_slaves(instance_count) if ratio >= 10
    poll
  end

  def instance_count
    byebug
    if (ratio_of_backlog_to_wip / 10.0).floor
  end

  def poll
    poller = Aws::SQS::QueuePoller.new(
      'https://sqs.us-west-2.amazonaws.com/828660616807/backlog')
    poller.poll do |msg|     
      run_program # run_job deletes message after it's finished
    end
  end

  def ratio_of_backlog_to_wip
    byebug
    wip = @s3.list_objects(bucket: 'render-wip').contents.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    @s3.list_objects(bucket: 'render-test').contents.count / wip
  end

  def start_slaves(instance_count)
    @ec2.request_spot_fleet(
      spot_fleet_request_config: slave_fleet_params(
        instance_count, best_price_and_zone_for(
          instance_type: 't2.micro',
          product_description: 'Windows')))
  end

  def slave_fleet_params(instance_count, options={})
    { client_token: 'render_slave_client_token',
    spot_price: options[:spot_price],
    target_capacity: instance_count,
    iam_fleet_role: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
    launch_specifications: [{
      image_id: 'ami-9384f7a3',
      key_name: 'render_slave_key_name',
      instance_type: 't2.micro',
      placement: { availability_zone: options[:availability_zone] }]
      iam_instance_profile: {
        arn: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
        name: 'render-man_fleet_request' }}}
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
    all_zones.each do |az|
      spot_prices << @ec2.describe_spot_price_history(
      start_time: (Time.now - 86400).iso8601.to_s,
      instance_types: [options[:instance_types]],
      product_descriptions: [options[:product_description]],
      availability_zone: az)
    end
    best_match = map_for_required_options spot_prices
    best_match[:spot_price] = add_buffer_to_price_in best_match
    best_match
  end

  def add_buffer_to_price_in(options)
    float_price = options[:spot_price].to_f
    options[:spot_price] = ((float_price + (float_price * 0.2)).round(3)).to_s
  end
  
  def all_zones
    @ec2.describe_availability_zones.availability_zones.map(&:zone_name)
  end
end

SpotMaker.new