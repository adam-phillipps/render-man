require 'spec_helper'

describe SpotMaker do
  it 'should configure itself' do
    expect(Subject).to be_kind_of SpotMkaer
  end

  it 'should count objects in backlog bucket' do
    expect(Subject.number_in_backlog).to be > 1
  end
end