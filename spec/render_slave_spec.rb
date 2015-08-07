require 'spec_helper'

describe RenderSlave do
  it 'should be a kind of RenderSlave' do
    expect(Subject).to be_kind_of RenderSlave
  end

  it 'should have a time left within 3300 seconds' do
    expect(Subject.time_left).to be <= 3300
  end
end