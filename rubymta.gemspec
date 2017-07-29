require_relative 'lib/rubymta/version'
include Version
Gem::Specification.new do |s|
  s.author        = "Michael J. Welch, Ph.D."
  s.files         = Dir.glob(["CHANGELOG.md", "LICENSE.md", "README.md", "rubymta.gemspec", "lib/*", "lib/rubymta/*", "spec/*", ".gitignore"])
  s.name          = 'rubymta'
  s.require_paths = ["lib"]
  s.summary       = "A Ruby Gem providing a complete Mail Transport Agent package."
  s.version       = VERSION
  s.date          = MODIFIED
  s.email         = 'mjwelchphd@gmail.com'
  s.homepage      = 'http://rubygems.org/gems/rubymta'
  s.license       = 'MIT'
  s.description   = "RubyMta is an experimental mail transport agent written in Ruby. See the README."
end
