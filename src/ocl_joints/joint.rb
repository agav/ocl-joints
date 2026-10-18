module OclJoints

  # Geometry of joints between two panels (no SketchUp API, so it can be tested outside SketchUp).
  #
  # Points and vectors are [x, y, z] Arrays in world inches (SketchUp's internal unit).
  #
  # A panel is a Box:
  #   origin: corner at the minimum of all three axes
  #   axes:   three unit vectors; axes[2] is the thickness axis
  #   size:   sizes along the axes; size[2] is the thickness
  #
  # A joint is an edge face of one panel (the edge panel) that touches the front or back face of
  # the other panel (the face panel).
  #
  # Component frames follow the f_ convention of ocl-viyar: the component origin is on the panel
  # surface and its Z axis is the outward normal of that surface, so holes go in -Z.
  module Joint

    MM = 1.0 / 25.4
    TOL = 0.5 * MM          # plane and point tolerance
    MIN_LENGTH = 1.0 * MM   # minimal contact length
    PARALLEL = 0.999        # |cos| above this: parallel
    PERPENDICULAR = 0.02    # |cos| below this: perpendicular

    Box = Struct.new(:origin, :axes, :size)

    # Contact of the edge panel with the face panel:
    #   corner:    a corner of the edge face; the (l, t) coordinates start here
    #   l_axis:    along the edge line, l in [0, length]
    #   t_axis:    the edge panel's thickness axis, t in [0, thickness]
    #   normal:    outward normal of the face panel's face (it points to the edge panel)
    #   thickness: edge panel thickness
    #   polygon:   contact area as [[l, t], ...]
    #   segment:   [l0, l1], the part of the edge middle line (t = thickness / 2) inside the contact
    #   inner:     +1 / -1: the side of t_axis where the face panel extends more; nil if equal
    Contact = Struct.new(:corner, :l_axis, :t_axis, :normal, :thickness, :polygon, :segment, :inner)

    module_function

    def add(a, b) = [ a[0] + b[0], a[1] + b[1], a[2] + b[2] ]
    def sub(a, b) = [ a[0] - b[0], a[1] - b[1], a[2] - b[2] ]
    def mul(a, s) = [ a[0] * s, a[1] * s, a[2] * s ]
    def dot(a, b) = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    def cross(a, b) = [ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] ]
    def length(a) = Math.sqrt(dot(a, a))

    def unit(a)
      len = length(a)
      len == 0 ? a : mul(a, 1.0 / len)
    end

    # Returns [ contact, edge_is_a ] for two panels, or nil if they do not touch edge-to-face.
    def joint(a, b)
      if (c = contact(a, b))
        [ c, true ]
      elsif (c = contact(b, a))
        [ c, false ]
      end
    end

    # Contact where an edge face of the edge box touches the front or back face of the face box, or nil.
    def contact(edge_box, face_box)
      best = nil
      [ 1, -1 ].each do |fs|
        n = mul(face_box.axes[2], fs)
        face_point = fs > 0 ? add(face_box.origin, mul(face_box.axes[2], face_box.size[2])) : face_box.origin
        [ 0, 1 ].each do |i|
          [ 1, -1 ].each do |es|
            next unless dot(mul(edge_box.axes[i], es), n) < -PARALLEL
            corner = es > 0 ? add(edge_box.origin, mul(edge_box.axes[i], edge_box.size[i])) : edge_box.origin
            next unless dot(sub(corner, face_point), n).abs <= TOL
            c = _contact(edge_box, face_box, corner, 1 - i, n)
            best = c if c && (best.nil? || _area(c.polygon) > _area(best.polygon))
          end
        end
      end
      best
    end

    # Edge positions (l values) for the pairs: crossings of guide lines with the edge middle line,
    # or the middle of the contact if no guide line fits.
    # A guide is { point:, direction:, start:, end: } (start / end are nil for an infinite line).
    def positions(contact, guides)
      l0, l1 = contact.segment
      middle_t = contact.thickness / 2.0
      found = []
      guides.each do |g|
        dir = unit(g[:direction])
        next unless dot(dir, contact.normal).abs < PERPENDICULAR && dot(dir, contact.l_axis).abs < PERPENDICULAR
        rel = sub(g[:point], contact.corner)
        next unless dot(rel, contact.normal).abs <= TOL
        l = dot(rel, contact.l_axis)
        next if l < l0 - TOL || l > l1 + TOL
        if g[:start] && g[:end]
          ts = [ g[:start], g[:end] ].map { |p| dot(sub(p, contact.corner), contact.t_axis) }
          next if middle_t < ts.min - TOL || middle_t > ts.max + TOL
        end
        l = l.clamp(l0, l1)
        found << l unless found.any? { |f| (f - l).abs <= TOL }
      end
      found.empty? ? [ (l0 + l1) / 2.0 ] : found.sort
    end

    # Second edge panel of a 3-panel joint: its edge touches the other face of the central panel,
    # on the same axis as the first edge panel (one through hole connects both).
    # first: contact of the first edge panel with the central panel; second_edge_box: the candidate.
    # Returns [ contact, segment ] or nil; segment is the common part of both edge middle lines,
    # as l values of the first contact.
    def third(first, second_edge_box, center_box)
      c = contact(second_edge_box, center_box)
      return nil if c.nil? || dot(c.normal, first.normal) > -PARALLEL
      return nil if dot(c.l_axis, first.l_axis).abs < PARALLEL
      # the first middle line, moved through the central panel, must be the second middle line
      a = joint_point(first, first.segment[0])
      shift = dot(sub(c.corner, a), c.normal)
      moved = add(a, mul(c.normal, shift))
      return nil if (dot(sub(moved, c.corner), c.t_axis) - c.thickness / 2.0).abs > TOL
      ls = c.segment.map { |l| dot(sub(joint_point(c, l), first.corner), first.l_axis) }
      s0 = [ first.segment[0], ls.min ].max
      s1 = [ first.segment[1], ls.max ].min
      return nil if s1 - s0 < MIN_LENGTH
      [ c, [ s0, s1 ] ]
    end

    # Point on the second middle line of a 3-panel joint, opposite to a point of the first one
    def opposite_point(second, point)
      add(point, mul(second.normal, dot(sub(second.corner, point), second.normal)))
    end

    # Point on the edge middle line at position l
    def joint_point(contact, l)
      add(contact.corner, add(mul(contact.l_axis, l), mul(contact.t_axis, contact.thickness / 2.0)))
    end

    # Joint frames { edge: [x, y, z], face: [x, y, z] } for the components.
    # Y points to the inner side (where the face panel extends more), so a rotation learned on one
    # joint keeps its meaning on other joints (for example a minifix cam inside the cabinet).
    def frames(contact)
      y = mul(contact.t_axis, contact.inner || 1)
      ze = mul(contact.normal, -1)
      zf = contact.normal
      { edge: [ cross(y, ze), y, ze ], face: [ cross(y, zf), y, zf ] }
    end

    # Local point of a component -> world point, for a component at point with frame axes, turned
    # k * 90 degrees about its Z axis
    def place(point, axes, k, local)
      x, y = _turn(local[0], local[1], k)
      add(point, add(mul(axes[0], x), add(mul(axes[1], y), mul(axes[2], local[2]))))
    end

    # Turns 0..3 that keep all feature points of the component on the surface of its panel and,
    # for points on the contact plane, inside the contact area
    def options(contact, box, point, axes, features)
      (0..3).select do |k|
        features.all? do |f|
          p = place(point, axes, k, f)
          on_surface?(box, p) && (!on_contact_plane?(contact, p) || in_contact?(contact, p))
        end
      end
    end

    # Selects the turns { edge:, face:, edge_options:, face_options: } for a pair.
    # Priority: matching holes on the contact plane, then the learned turns, then features of the
    # edge component (minifix cam) on the inner side, then the lowest turns.
    def predict(contact, point, edge_box, edge_features, face_box, face_features, learned = nil)
      fr = frames(contact)
      eo = options(contact, edge_box, point, fr[:edge], edge_features)
      fo = options(contact, face_box, point, fr[:face], face_features)
      eo = [ 0, 1, 2, 3 ] if eo.empty?
      fo = [ 0, 1, 2, 3 ] if fo.empty?
      ke, kf = eo.product(fo).max_by do |e, f|
        edge_points = edge_features.map { |p| place(point, fr[:edge], e, p) }
        face_points = face_features.map { |p| place(point, fr[:face], f, p) }
        [ _matches(contact, edge_points, face_points),
          learned && learned[:edge] == e && learned[:face] == f ? 1 : 0,
          _inner_score(contact, point, edge_points),
          -(e + f) ]
      end
      { edge: ke, face: kf, edge_options: eo, face_options: fo }
    end

    # Next turn in options after k, in direction step (+1 / -1)
    def next_option(options, k, step)
      return k if options.empty?
      i = options.index(k)
      return options.first if i.nil?
      options[(i + step) % options.length]
    end

    def on_surface?(box, p)
      rel = sub(p, box.origin)
      c = (0..2).map { |i| dot(rel, box.axes[i]) }
      inside = (0..2).all? { |i| c[i] >= -TOL && c[i] <= box.size[i] + TOL }
      inside && (0..2).any? { |i| c[i].abs <= TOL || (c[i] - box.size[i]).abs <= TOL }
    end

    def on_contact_plane?(contact, p)
      dot(sub(p, contact.corner), contact.normal).abs <= TOL
    end

    def in_contact?(contact, p)
      rel = sub(p, contact.corner)
      _inside?(contact.polygon, [ dot(rel, contact.l_axis), dot(rel, contact.t_axis) ])
    end

    # Point on the edge middle line nearest to a ray (for dragging); returns l, not clamped
    def nearest_l(contact, ray_origin, ray_direction)
      p = joint_point(contact, 0)
      u = contact.l_axis
      v = unit(ray_direction)
      w = sub(p, ray_origin)
      b = dot(u, v)
      denom = 1 - b * b
      return dot(sub(ray_origin, p), u) if denom.abs < 1e-9
      (b * dot(v, w) - dot(u, w)) / denom
    end

    def _contact(edge_box, face_box, corner, l_index, n)
      l_axis = edge_box.axes[l_index]
      t_axis = edge_box.axes[2]
      length = edge_box.size[l_index]
      thickness = edge_box.size[2]
      to_lt = ->(p) { r = sub(p, corner); [ dot(r, l_axis), dot(r, t_axis) ] }
      o, a, b = face_box.origin, mul(face_box.axes[0], face_box.size[0]), mul(face_box.axes[1], face_box.size[1])
      face = [ o, add(o, a), add(add(o, a), b), add(o, b) ].map(&to_lt)
      polygon = _clip(face, length, thickness)
      return nil if polygon.length < 3

      segment = _crossing(polygon, thickness / 2.0)
      return nil if segment.nil? || segment[1] - segment[0] < MIN_LENGTH

      ts = face.map { |p| p[1] }
      below = -ts.min
      above = ts.max - thickness
      inner = if above > below + TOL then 1 elsif below > above + TOL then -1 end
      Contact.new(corner, l_axis, t_axis, n, thickness, polygon, segment, inner)
    end

    # Sutherland-Hodgman clipping of a polygon by the rectangle [0, w] x [0, h]
    def _clip(polygon, w, h)
      [ [ 0, 0, 1 ], [ 0, w, -1 ], [ 1, 0, 1 ], [ 1, h, -1 ] ].reduce(polygon) do |poly, (axis, limit, sign)|
        next poly if poly.empty?
        out = []
        poly.each_with_index do |cur, i|
          prev = poly[i - 1]
          cur_in = (cur[axis] - limit) * sign >= -1e-9
          prev_in = (prev[axis] - limit) * sign >= -1e-9
          if cur_in != prev_in
            r = (limit - prev[axis]) / (cur[axis] - prev[axis])
            out << [ prev[0] + r * (cur[0] - prev[0]), prev[1] + r * (cur[1] - prev[1]) ]
          end
          out << cur if cur_in
        end
        out
      end
    end

    # [min l, max l] where the line t = m crosses the convex polygon, or nil
    def _crossing(polygon, m)
      ls = []
      polygon.each_with_index do |q, i|
        p = polygon[i - 1]
        if (p[1] - m).abs < 1e-9 && (q[1] - m).abs < 1e-9
          ls << p[0] << q[0]
        elsif (p[1] - m) * (q[1] - m) <= 0
          ls << p[0] + (m - p[1]) / (q[1] - p[1]) * (q[0] - p[0])
        end
      end
      ls.empty? ? nil : [ ls.min, ls.max ]
    end

    def _area(polygon)
      polygon.each_with_index.sum { |q, i| p = polygon[i - 1]; p[0] * q[1] - q[0] * p[1] }.abs / 2.0
    end

    # Point inside a convex polygon, with tolerance
    def _inside?(polygon, pt)
      signed = polygon.each_with_index.sum { |q, i| p = polygon[i - 1]; p[0] * q[1] - q[0] * p[1] }
      orient = signed >= 0 ? 1 : -1
      polygon.each_with_index.all? do |q, i|
        p = polygon[i - 1]
        ex, ey = q[0] - p[0], q[1] - p[1]
        len = Math.sqrt(ex * ex + ey * ey)
        next true if len == 0
        (ex * (pt[1] - p[1]) - ey * (pt[0] - p[0])) * orient / len >= -TOL
      end
    end

    def _turn(x, y, k)
      case k % 4
      when 0 then [ x, y ]
      when 1 then [ -y, x ]
      when 2 then [ -x, -y ]
      else [ y, -x ]
      end
    end

    # Number of edge component points on the contact plane that have a face component point at the same place
    def _matches(contact, edge_points, face_points)
      on_plane = face_points.select { |p| on_contact_plane?(contact, p) }
      edge_points.count do |e|
        on_contact_plane?(contact, e) && on_plane.any? { |f| length(sub(e, f)) <= TOL }
      end
    end

    # Edge component points off the contact plane: +1 for each on the inner side, -1 on the outer side
    def _inner_score(contact, point, edge_points)
      return 0 if contact.inner.nil?
      y = mul(contact.t_axis, contact.inner)
      edge_points.sum do |p|
        next 0 if on_contact_plane?(contact, p)
        d = dot(sub(p, point), y)
        d > TOL ? 1 : (d < -TOL ? -1 : 0)
      end
    end

  end

end
