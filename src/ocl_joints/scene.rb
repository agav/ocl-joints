require 'securerandom'

module OclJoints

  # SketchUp side: panels, guide lines, component features, adding and finding the pairs.
  module Scene

    FEATURE_RE = /\A\s*[fg]_/i
    DICTIONARY = 'ocl_joints'

    # A panel instance with its full path from the model root
    #   transformation: definition space -> world
    #   box:            Joint::Box in world inches
    Panel = Struct.new(:path, :transformation, :box) do
      def key = path.map(&:entityID).join('/')
      def definition = path.last.definition
      def name = path.last.name.empty? ? definition.name : path.last.name
    end

    # One placed component of a pair
    Part = Struct.new(:panel, :instance) do
      def transformation = panel.transformation * instance.transformation
    end

    Pair = Struct.new(:id, :row, :edge, :face)

    module_function

    # f_ / g_ surface components (instance or definition name)
    def feature?(entity)
      return false unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      !!(entity.name =~ FEATURE_RE || entity.definition.name =~ FEATURE_RE)
    end

    # A panel is a group or component, not a surface component, with faces of its own
    def panel_entity?(entity)
      return false unless entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
      return false if feature?(entity)
      entity.definition.entities.any? { |e| e.is_a?(Sketchup::Face) }
    end

    # All visible panels of the model. Panels inside panels are not searched.
    def panels(model)
      found = []
      _walk(model.entities, [], Geom::Transformation.new, found)
      found
    end

    def _walk(entities, path, transformation, found)
      entities.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        next unless e.visible? && e.layer.visible?
        next if feature?(e)
        t = transformation * e.transformation
        if panel_entity?(e)
          box = _box(e.definition, t)
          found << Panel.new(path + [ e ], t, box) if box
        else
          _walk(e.definition.entities, path + [ e ], t, found)
        end
      end
    end

    # Oriented box of the panel faces (surface components excluded), thickness axis last
    def _box(definition, t)
      bb = Geom::BoundingBox.new
      _each_face(definition.entities, nil, false) do |face, ft|
        face.vertices.each { |v| bb.add(ft ? v.position.transform(ft) : v.position) }
      end
      return nil if bb.empty?
      origin = bb.min.transform(t)
      vectors = [ [ bb.width, 0, 0 ], [ 0, bb.height, 0 ], [ 0, 0, bb.depth ] ].map do |v|
        Geom::Vector3d.new(*v).transform(t)
      end
      sizes = vectors.map(&:length).map(&:to_f)
      return nil if sizes.min <= 0
      order = [ 0, 1, 2 ].sort_by { |i| -sizes[i] }
      Joint::Box.new(origin.to_a, order.map { |i| vectors[i].normalize.to_a }, order.map { |i| sizes[i] })
    end

    # Yields each visible face with its transformation into the definition (nil at the top level).
    # with_features: false skips f_ / g_ subtrees (panel geometry only).
    def _each_face(entities, transformation, with_features, &block)
      entities.each do |e|
        if e.is_a?(Sketchup::Face)
          yield e, transformation if e.visible? && e.layer.visible?
        elsif (e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)) && e.visible?
          next if !with_features && feature?(e)
          t = transformation ? transformation * e.transformation : e.transformation
          _each_face(e.definition.entities, t, with_features, &block)
        end
      end
    end

    # Triangles [p1, p2, p3, ...] of a definition, in definition space
    def triangles(definition, with_features = false)
      points = []
      _each_face(definition.entities, nil, with_features) do |face, t|
        mesh = face.mesh(0)
        mesh.polygons.each do |polygon|
          polygon.each do |i|
            p = mesh.point_at(i.abs)
            points << (t ? p.transform(t) : p)
          end
        end
      end
      points
    end

    # Edge segments [p1, p2, ...] of a definition and everything inside it, in definition space
    def lines(definition, transformation = nil, points = [])
      definition.entities.each do |e|
        if e.is_a?(Sketchup::Edge)
          next unless e.visible?
          [ e.start.position, e.end.position ].each { |p| points << (transformation ? p.transform(transformation) : p) }
        elsif e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
          lines(e.definition, transformation ? transformation * e.transformation : e.transformation, points)
        end
      end
      points
    end

    # Feature points of a surface component: origins of the f_ components inside it
    # (through g_ containers), or its own origin if it is an f_ component itself
    def feature_points(definition)
      return [ [ 0.0, 0.0, 0.0 ] ] if definition.name =~ /\A\s*f_/i
      points = []
      _features(definition.entities, Geom::Transformation.new, points)
      points.empty? ? [ [ 0.0, 0.0, 0.0 ] ] : points
    end

    def _features(entities, transformation, points)
      entities.each do |e|
        next unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        names = [ e.name, e.definition.name ]
        t = transformation * e.transformation
        if names.any? { |n| n =~ /\A\s*f_/i }
          points << t.origin.to_a
        elsif names.any? { |n| n =~ /\A\s*g_/i }
          _features(e.definition.entities, t, points)
        end
      end
    end

    # Guide lines in the model root, in the parent groups of the panels and in the panels.
    # Returns [ { point:, direction:, start:, end: }, ... ] in world inches.
    def guides(model, panel_list)
      containers = [ [ model.entities, Geom::Transformation.new ] ]
      panel_list.each do |panel|
        t = Geom::Transformation.new
        panel.path.each do |e|
          t *= e.transformation
          containers << [ e.definition.entities, t ]
        end
      end
      seen = {}
      result = []
      containers.each do |entities, t|
        entities.grep(Sketchup::ConstructionLine).each do |cl|
          next unless cl.visible? && cl.layer.visible?
          key = [ cl.entityID, t.to_a ]
          next if seen[key]
          seen[key] = true
          result << { point: cl.position.transform(t).to_a, direction: cl.direction.transform(t).to_a,
                      start: cl.start && cl.start.transform(t).to_a, end: cl.end && cl.end.transform(t).to_a }
        end
      end
      result
    end

    # Component definition by name: from the model, or loaded from <name>.skp in a library folder
    def definition(model, name, library)
      defs = model.definitions.reject { |d| d.group? || d.image? }
      found = defs.find { |d| d.name == name } || defs.find { |d| d.name.casecmp?(name) }
      return found if found
      library.each do |folder|
        file = Dir.glob(File.join(folder.tr('\\', '/'), '**', '*.skp')).find { |f| File.basename(f, '.*').casecmp?(name) }
        return model.definitions.load(file) if file
      end
      nil
    end

    # World transformation of a component at point with frame axes, turned k * 90 degrees
    def world_transformation(point, axes, k)
      Geom::Transformation.axes(Geom::Point3d.new(*point), *axes.map { |a| Geom::Vector3d.new(*a) }) *
        Geom::Transformation.rotation(ORIGIN, Z_AXIS, k * 90.degrees)
    end

    # Adds a component into the panel definition at a world transformation
    def add(panel, definition, world, pair_id, role, row)
      local = panel.transformation.inverse * world
      # in a mirrored panel the local transformation is mirrored too: mirror the component back
      # along its X axis (the edge line), so it keeps a normal transformation
      local *= Geom::Transformation.scaling(-1, 1, 1) if _determinant(local) < 0
      instance = panel.definition.entities.add_instance(definition, local)
      instance.set_attribute(DICTIONARY, 'pair_id', pair_id)
      instance.set_attribute(DICTIONARY, 'role', role)
      instance.set_attribute(DICTIONARY, 'row', row)
      instance
    end

    def new_pair_id = SecureRandom.uuid

    # The pair of a placed component (part in panel), or nil if its other component is missing
    def pair(panels, panel, instance)
      id = instance.get_attribute(DICTIONARY, 'pair_id')
      role = instance.get_attribute(DICTIONARY, 'role')
      return nil if id.nil?
      here = Part.new(panel, instance)
      origin = here.transformation.origin
      other = nil
      best = nil
      panels.each do |p|
        next if p.definition == panel.definition && p.key == panel.key
        p.definition.entities.grep(Sketchup::ComponentInstance).each do |i|
          next unless i.get_attribute(DICTIONARY, 'pair_id') == id && i.get_attribute(DICTIONARY, 'role') != role
          part = Part.new(p, i)
          d = part.transformation.origin.distance(origin)
          other, best = part, d if best.nil? || d < best
        end
      end
      return nil if other.nil?
      row = instance.get_attribute(DICTIONARY, 'row')
      role == 'edge' ? Pair.new(id, row, here, other) : Pair.new(id, row, other, here)
    end

    # Moves a placed component by a world vector
    def move(part, vector)
      local = Geom::Vector3d.new(*vector).transform(part.panel.transformation.inverse)
      part.instance.transform!(Geom::Transformation.translation(local))
    end

    def _determinant(t)
      m = t.to_a
      x = Geom::Vector3d.new(m[0], m[1], m[2])
      y = Geom::Vector3d.new(m[4], m[5], m[6])
      z = Geom::Vector3d.new(m[8], m[9], m[10])
      (x * y) % z
    end

  end

end
