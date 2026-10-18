require 'sketchup.rb'
require 'extensions.rb'

module OclJoints

  unless file_loaded?(__FILE__)
    ex = SketchupExtension.new('OCL Joints', File.join(File.dirname(__FILE__), 'ocl_joints', 'main'))
    ex.version     = '0.1.0'
    ex.creator     = 'Oleksandr Gavrylenko'
    ex.copyright   = 'Oleksandr Gavrylenko'
    ex.description = 'Places pairs of surface components (minifix, confirmat, dowels) where an edge of one panel touches the face of another panel.'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end

end
