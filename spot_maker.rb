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
      region: ENV['AWS_REGION'],
      credentials: creds)
    @ec2 = Aws::EC2::Client.new(
      region: ENV['AWS_REGION'],
      credentials: creds)
    poll
  end

  def run_program
    ratio = ratio_of_backlog_to_wip
    start_slaves(ratio / 10) if ratio >= 10
    poll
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
    wip = wip.elq? 0 ? .01 : wip # guards agains dividing by zero
    @s3.list_objects(bucket: 'render-test').contents.count / wip
  end

  def start_slaves(instance_count)
    @ec2.request_spot_fleet(
      slave_fleet_params(instance_count))
  end

  def slave_fleet_params(instance_count)
  end

  def map_for_required_options(spot_prices)
    byebug
    spot_prices.each.map(&:spot_price_history).flatten.
      map{ |sph| {spot_price: sph.spot_price, availability_zone: sph.availability_zone, instance_type: sph.instance_type} }.
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
end

SpotMaker.new