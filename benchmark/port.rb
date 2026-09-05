# frozen_string_literal: true
# warn_indent: true

require "bundler/setup"
require "benchmark/ips"
require "farce"

ractor_port = Ractor::Port.new
farce_port  = Farce::Port.new

Benchmark.ips do |x|
  x.report("Ractor::Port.send(unshareable)") { ractor_port.send(Object.new).receive }
  x.report("Ractor::Port.send(unshareable, move: true)") { ractor_port.send(Object.new, move: true).receive }
  x.report("Ractor::Port.send(shareable)") { ractor_port.send(Object.new.freeze).receive }
  x.report("Farce::Port.send(unshareable)")  { farce_port.send(Object.new).receive }
  x.report("Farce::Port.send(unshareable, move: true)") { farce_port.send(Object.new, move: true).receive }
  x.report("Farce::Port.send(unshareable, mode: :local)") { farce_port.send(Object.new, mode: :local).receive }
  x.report("Farce::Port.send(shareable)") { farce_port.send(Object.new.freeze).receive }
  x.compare!
end
