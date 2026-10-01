require 'sketchup.rb'
require 'extensions.rb'
module Gablehip
  unless defined?(EXTENSION)
    EXTENSION=SketchupExtension.new('Gablehip','gablehip/main')
    EXTENSION.version='3.0.1'
    EXTENSION.creator='ZONIUM'
    Sketchup.register_extension(EXTENSION,true)
  end
end
