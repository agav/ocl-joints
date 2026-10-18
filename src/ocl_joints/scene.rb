require 'securerandom'

module OclJoints

  # SketchUp side: panels, guide lines, component features, adding and finding the pairs.
  module Scene

    FEATURE_RE = /\A\s*[fg]_/i
    DICTIONARY = 'ocl_joints'
    MATCH_TOL = 1.0 / 25.4   # origins of a hand-placed pair closer than this make a pair

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

    # A joint: edge and face components; a 3-panel joint also has edge2, the edge component of the
    # panel on the other face of the central (face) panel. edge is on the face component side.
    Pair = Struct.new(:id, :row, :edge, :face, :edge2) do
      def parts = [ edge, face, edge2 ].compact
      def triple? = !edge2.nil?
    end

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

    # Component definition by name: from the model, or loaded from <name>.skp in a library folder.
    # In the model the name can also be a definition name with SketchUp's "#1" suffix, or the name
    # of an instance (ocl-viyar reads f_ / g_ names from instances too).
    def definition(model, name, library)
      name = name.to_s.strip
      return nil if name.empty?
      defs = model.definitions.reject { |d| d.group? || d.image? }
      found = defs.find { |d| d.name == name } ||
              defs.find { |d| d.name.casecmp?(name) } ||
              defs.find { |d| d.name.sub(/#\d+\z/, '').casecmp?(name) } ||
              defs.find { |d| d.instances.any? { |i| i.name.strip.casecmp?(name) } }
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
    def add(panel, definition, world, pair_id, role, row, turn = nil, triple: false)
      local = panel.transformation.inverse * world
      # in a mirrored panel the local transformation is mirrored too: mirror the component back
      # along its X axis (the edge line), so it keeps a normal transformation
      local *= Geom::Transformation.scaling(-1, 1, 1) if _determinant(local) < 0
      instance = panel.definition.entities.add_instance(definition, local)
      instance.set_attribute(DICTIONARY, 'pair_id', pair_id)
      instance.set_attribute(DICTIONARY, 'role', role)
      instance.set_attribute(DICTIONARY, 'row', row)
      instance.set_attribute(DICTIONARY, 'turn', turn) if turn
      instance.set_attribute(DICTIONARY, 'kind', 'triple') if triple
      _glue(instance)
      instance
    end

    # Turn (0..3) of a placed component in its joint frame: from its attribute, or for components
    # without it, from the direction of its Y axis (a mirror along X does not change Y)
    def turn(part, axes)
      k = part.instance.get_attribute(DICTIONARY, 'turn')
      return k if k.is_a?(Integer)
      y = part.transformation.yaxis.normalize.to_a
      x, fy = axes
      [ fy, Joint.mul(x, -1), Joint.mul(fy, -1), x ].each_with_index.max_by { |v, _| Joint.dot(v, y) }.last
    end

    # Glues the component to the panel face under its origin, as SketchUp does when the component
    # is placed by hand: the face must have the same normal as the component Z axis.
    # Components without "Glue to" behaviour stay unglued.
    def _glue(instance)
      return unless instance.definition.behavior.is2d?
      t = instance.transformation
      origin = t.origin
      z = t.zaxis
      face = instance.parent.entities.grep(Sketchup::Face).find do |f|
        f.normal.parallel?(z) && f.normal % z > 0 && f.plane && origin.on_plane?(f.plane) &&
          [ Sketchup::Face::PointInside, Sketchup::Face::PointOnEdge, Sketchup::Face::PointOnVertex ].include?(f.classify_point(origin))
      end
      instance.glued_to = face if face
    rescue ArgumentError
      nil
    end

    def new_pair_id = SecureRandom.uuid

    # Copy of a placed component at the same place, with a new pair id
    def duplicate(part, pair_id)
      old = part.instance
      instance = part.panel.definition.entities.add_instance(old.definition, old.transformation)
      instance.name = old.name
      instance.layer = old.layer
      instance.material = old.material
      instance.set_attribute(DICTIONARY, 'pair_id', pair_id)
      instance.set_attribute(DICTIONARY, 'role', old.get_attribute(DICTIONARY, 'role'))
      row = old.get_attribute(DICTIONARY, 'row')
      instance.set_attribute(DICTIONARY, 'row', row) if row
      %w[turn kind].each do |key|
        value = old.get_attribute(DICTIONARY, key)
        instance.set_attribute(DICTIONARY, key, value) if value
      end
      _glue(instance)
      Part.new(part.panel, instance)
    end

    # Copy of a pair at the same place
    def duplicate_pair(pair)
      id = new_pair_id
      Pair.new(id, pair.row, duplicate(pair.edge, id), duplicate(pair.face, id), pair.edge2 && duplicate(pair.edge2, id))
    end

    # The joint of a placed component (part in panel), or nil if a component is missing.
    # Components of other panels with the same pair id are found; for each role the nearest one is
    # used (a shared definition has the same component in all its instances).
    def pair(panels, panel, instance)
      id = instance.get_attribute(DICTIONARY, 'pair_id')
      role = instance.get_attribute(DICTIONARY, 'role')
      return nil if id.nil?
      triple = instance.get_attribute(DICTIONARY, 'kind') == 'triple'
      here = Part.new(panel, instance)
      origin = here.transformation.origin
      found = { 'edge' => [], 'face' => [] }
      panels.each do |p|
        next if p.key == panel.key
        p.definition.entities.grep(Sketchup::ComponentInstance).each do |i|
          next unless i.get_attribute(DICTIONARY, 'pair_id') == id
          list = found[i.get_attribute(DICTIONARY, 'role')]
          part = Part.new(p, i)
          list << [ part.transformation.origin.distance(origin), part ] if list
        end
      end
      edges = found['edge'].sort_by(&:first).map(&:last)
      face = role == 'face' ? here : found['face'].min_by(&:first)&.last
      edge = role == 'edge' ? here : edges.shift
      return nil if face.nil? || edge.nil?
      edge2 = nil
      if triple
        edge2 = edges.find { |e| e.panel.key != edge.panel.key }
        return nil if edge2.nil?
        face_origin = face.transformation.origin
        if face_origin.distance(edge2.transformation.origin) < face_origin.distance(edge.transformation.origin)
          edge, edge2 = edge2, edge
        end
      end
      Pair.new(id, instance.get_attribute(DICTIONARY, 'row'), edge, face, edge2)
    end

    # Pair of a surface component placed by hand (no pair_id): the surface component of a connected
    # panel with the origin at the same place. Pair id is nil until link writes it.
    # rows: connector table, to find the connector name from the component names.
    def manual_pair(panels, panel, instance, rows)
      return nil unless feature?(instance) && instance.parent == panel.definition
      here = Part.new(panel, instance)
      origin = here.transformation.origin.to_a
      best = nil
      panels.each do |p|
        next if p.key == panel.key
        contact, here_is_edge = Joint.joint(panel.box, p.box)
        next unless contact && Joint.on_contact_plane?(contact, origin) && Joint.in_contact?(contact, origin)
        p.definition.entities.each do |e|
          next unless feature?(e)
          part = Part.new(p, e)
          d = Joint.length(Joint.sub(part.transformation.origin.to_a, origin))
          next if d > MATCH_TOL || (best && d >= best[0])
          best = [ d, here_is_edge ? [ here, part ] : [ part, here ] ]
        end
      end
      return nil if best.nil?
      edge, face = best[1]
      row = rows.find { |r| component_name?(edge.instance, r[:edge]) && component_name?(face.instance, r[:face]) }
      Pair.new(nil, row && row[:name], edge, face)
    end

    def component_name?(instance, name)
      [ instance.definition.name, instance.name ].any? { |n| n.sub(/#\d+\z/, '').casecmp?(name) }
    end

    # Pair with a pair id written to both components (a hand-placed pair gets one now)
    def link(pair)
      return pair if pair.id
      id = new_pair_id
      [ [ pair.edge, 'edge' ], [ pair.face, 'face' ] ].each do |part, role|
        part.instance.set_attribute(DICTIONARY, 'pair_id', id)
        part.instance.set_attribute(DICTIONARY, 'role', role)
        part.instance.set_attribute(DICTIONARY, 'row', pair.row) if pair.row
      end
      Pair.new(id, pair.row, pair.edge, pair.face, pair.edge2)
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
