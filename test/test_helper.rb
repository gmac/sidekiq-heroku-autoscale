require 'minitest/autorun'
require 'minitest/pride'
require 'sidekiq_heroku_autoscale'

class MockQueueSystem
	attr_accessor :total_work, :workers

	def initialize
		@total_work = 0
		@workers = 0
	end

	def has_work?
		total_work > 0
	end
end