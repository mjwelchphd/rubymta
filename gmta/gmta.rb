#! /usr/bin/env ruby

require 'rubymta'

begin
  Server.new.start
rescue => e
  puts "Catastrophic failure => %s"%e
  puts e.backtrace
end
