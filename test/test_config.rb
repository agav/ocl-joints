require 'minitest/autorun'
require_relative '../src/ocl_joints/config'

class TestConfig < Minitest::Test

  C = OclJoints::Config

  def test_default_for_empty_or_bad_json
    assert_equal C.default, C.parse(nil)
    assert_equal C.default, C.parse('{bad')
    assert_equal 4, C.default[:rows].length
  end

  def test_round_trip
    config = { library: [ 'C:/prj/skp/components' ],
               rows: [ { name: 'minifix', face: 'f_d5x11.5', edge: 'g_minifix-edge', learned: { edge: 2, face: 0 } } ],
               triples: [ { name: 'double', face: 'f_d10xF', edge: 'g_minifix-edge' } ] }
    assert_equal config, C.parse(C.dump(config))
  end

  def test_normalize_cleans_rows
    config = C.normalize({ library: [ ' ', 'D:/lib ' ],
                           rows: [ { name: '', face: 'f_d8x12', edge: ' f_d8.5x25 ', learned: { edge: 5, face: 0 } },
                                   { name: 'empty', face: '', edge: '' }, 'junk' ] })
    assert_equal [ 'D:/lib' ], config[:library]
    assert_equal [ { name: 'f_d8.5x25', face: 'f_d8x12', edge: 'f_d8.5x25' } ], config[:rows]
  end

end
