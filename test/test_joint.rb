require 'minitest/autorun'
require_relative '../src/ocl_joints/joint'

class TestJoint < Minitest::Test

  G = OclJoints::Joint
  X = [ 1.0, 0, 0 ].freeze
  Y = [ 0, 1.0, 0 ].freeze
  Z = [ 0, 0, 1.0 ].freeze

  def mm(*v) = v.map { |a| a / 25.4 }

  # Cabinet 600 x 500 x 720, panels 18 mm: left side x 0..18, bottom between the sides
  def side
    G::Box.new(mm(0, 0, 0), [ Y, Z, X ], mm(500, 720, 18))
  end

  def bottom
    G::Box.new(mm(18, 0, 0), [ X, Y, Z ], mm(564, 500, 18))
  end

  def top
    G::Box.new(mm(18, 0, 702), [ X, Y, Z ], mm(564, 500, 18))
  end

  def shelf(z)
    G::Box.new(mm(18, 20, z), [ X, Y, Z ], mm(564, 460, 18))
  end

  MINIFIX_EDGE = [ [ 0, 0, 0 ], [ 0, 9 / 25.4, -34 / 25.4 ] ].freeze   # edge hole, cam 34 mm in on the +Y face
  MINIFIX_FACE = [ [ 0, 0, 0 ] ].freeze
  DOWELS_EDGE = (MINIFIX_EDGE + [ [ 32 / 25.4, 0, 0 ], [ -32 / 25.4, 0, 0 ] ]).freeze
  DOWELS_FACE = [ [ 0, 0, 0 ], [ 32 / 25.4, 0, 0 ], [ -32 / 25.4, 0, 0 ] ].freeze

  def assert_vec(expected, actual)
    expected.zip(actual).each { |e, a| assert_in_delta e, a, 1e-6 }
  end

  def test_contact_bottom_on_side
    c, edge_is_a = G.joint(bottom, side)
    assert edge_is_a
    assert_vec X, c.normal
    assert_vec Y, c.l_axis
    assert_vec Z, c.t_axis
    assert_vec mm(0, 500), c.segment
    assert_equal 1, c.inner
    assert_vec mm(18, 250, 9), G.joint_point(c, G.positions(c, []).first)
  end

  def test_joint_finds_edge_panel_in_either_order
    c, edge_is_a = G.joint(side, bottom)
    refute edge_is_a
    assert_vec X, c.normal
  end

  def test_no_contact_face_to_face_or_apart
    other_side = G::Box.new(mm(0, 0, 0), [ Y, Z, X ], mm(500, 720, 18))
    assert_nil G.joint(side, other_side)
    apart = G::Box.new(mm(19, 0, 0), [ X, Y, Z ], mm(564, 500, 18))
    assert_nil G.joint(apart, side)
  end

  def test_contact_uses_overlap_only
    c = G.contact(shelf(300), side)
    assert_vec mm(0, 460), c.segment   # l starts at the shelf corner (y = 20)
    assert_vec mm(18, 20, 309), c.corner.zip(mm(0, 0, 9)).map { |a, b| a + b }
  end

  def test_inner_side_top_and_middle_shelf
    assert_equal(-1, G.contact(top, side).inner)
    assert_nil G.contact(shelf(351), side).inner
  end

  def test_guide_lines
    c = G.contact(bottom, side)
    guides = [
      { point: mm(18, 100, 0), direction: Z },                        # fits
      { point: mm(18, 400, -50), direction: Z, start: mm(18, 400, -50), end: mm(18, 400, 50) }, # fits, finite
      { point: mm(18, 300, 0), direction: X },                        # perpendicular to the plane
      { point: mm(10, 200, 0), direction: Z },                        # not in the plane
      { point: mm(18, 450, 100), direction: Z, start: mm(18, 450, 100), end: mm(18, 450, 200) }, # misses the edge
      { point: mm(18, 100.2, 50), direction: [ 0, 0, -1.0 ] },        # same crossing as the first
    ]
    assert_vec mm(100, 400), G.positions(c, guides)
  end

  def test_minifix_cam_goes_inside_bottom
    c = G.contact(bottom, side)
    point = G.joint_point(c, 250 / 25.4)
    r = G.predict(c, point, bottom, MINIFIX_EDGE, side, MINIFIX_FACE)
    assert_equal [ 0, 2 ], r[:edge_options]
    cam = G.place(point, G.frames(c)[:edge], r[:edge], MINIFIX_EDGE[1])
    assert_vec mm(52, 250, 18), cam   # 34 mm from the edge, on the top face of the bottom
  end

  def test_minifix_cam_goes_inside_top
    c = G.contact(top, side)
    point = G.joint_point(c, 250 / 25.4)
    r = G.predict(c, point, top, MINIFIX_EDGE, side, MINIFIX_FACE)
    cam = G.place(point, G.frames(c)[:edge], r[:edge], MINIFIX_EDGE[1])
    assert_vec mm(52, 250, 702), cam   # bottom face of the top
  end

  def test_dowels_align_with_edge
    c = G.contact(bottom, side)
    point = G.joint_point(c, 250 / 25.4)
    r = G.predict(c, point, bottom, DOWELS_EDGE, side, DOWELS_FACE)
    assert_equal [ 0, 2 ], r[:face_options]
    fr = G.frames(c)
    edge_points = DOWELS_EDGE.map { |p| G.place(point, fr[:edge], r[:edge], p) }
    face_points = DOWELS_FACE.map { |p| G.place(point, fr[:face], r[:face], p) }
    face_points.each { |f| assert(edge_points.any? { |e| G.length(G.sub(e, f)) < 1e-6 }) }
  end

  def test_learned_turn_wins_over_inner_side
    c = G.contact(bottom, side)
    point = G.joint_point(c, 250 / 25.4)
    r = G.predict(c, point, bottom, MINIFIX_EDGE, side, MINIFIX_FACE, { edge: 2, face: 1 })
    assert_equal [ 2, 1 ], [ r[:edge], r[:face] ]
  end

  def test_next_option
    assert_equal 2, G.next_option([ 0, 2 ], 0, 1)
    assert_equal 0, G.next_option([ 0, 2 ], 2, 1)
    assert_equal 3, G.next_option([ 0, 1, 2, 3 ], 0, -1)
  end

  def test_nearest_l
    c = G.contact(bottom, side)
    l = G.nearest_l(c, mm(-1000, 120, 500), [ 1.0, 0, -0.3 ])
    assert_in_delta 120 / 25.4, l, 1e-6
  end

end
