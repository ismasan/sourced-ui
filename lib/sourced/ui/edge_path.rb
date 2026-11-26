# frozen_string_literal: true

module Sourced
  module UI
    # SVG paths for the edges a LayeredLayout routes, shared by the drawings
    # that use it (Components::Statechart, Components::BoundaryMap).
    module EdgePath
      module_function

      # A curve through every point, the way Pele (pele.run) draws its
      # layered edges: two points in line are joined by a straight run, and
      # any other two by one S that leaves and arrives upright, so a line
      # meets boxes square and never overshoots a bend. A point in between
      # that its line passes on the way across (it lies between the points
      # either side) is swept through, heading from the one before to the one
      # after, rather than stepped; so is one it turns back at (the lowest
      # point of a line under a rank). An S's handles reach half the way down
      # (#ease), and a sweep's a third of its stretch; neither past the
      # stretch's top or bottom, so it never doubles back up or down.
      def spline(points)
        points = points.chunk_while { |p, q| (p[0] - q[0]).abs < 0.01 && (p[1] - q[1]).abs < 0.01 }.map(&:first)
        return "M #{f points[0][0]} #{f points[0][1]}" if points.size < 2

        last = points.size - 1
        # nil: upright. Else the unit heading it sweeps through on.
        sweeps = points.each_index.map do |i|
          next nil if i.zero? || i == last

          (px, py), (x, y), (nx, ny) = points[i - 1], points[i], points[i + 1]
          across = (x - px) * (nx - x) > 0.01
          turns = (y - py) * (ny - y) < -0.01
          next nil unless across || turns

          length = Math.hypot(nx - px, ny - py)
          [(nx - px) / length, (ny - py) / length]
        end
        d = +"M #{f points[0][0]} #{f points[0][1]}"
        points.each_cons(2).with_index do |((x1, y1), (x2, y2)), i|
          if (x1 - x2).abs < 0.5 && !sweeps[i] && !sweeps[i + 1]
            # Straight on: a point part way along a run adds nothing.
            d << " L #{f x2} #{f y2}" unless i + 1 < last && !sweeps[i + 1] && (points[i + 2][0] - x2).abs < 0.5
            next
          end
          dy = y2 - y1
          s_reach = dy.abs * ease(x2 - x1, dy)
          reach = Math.hypot(x2 - x1, dy) / 3
          c1 = sweeps[i] ? [x1 + sweeps[i][0] * reach, y1 + sweeps[i][1] * reach] : [x1, y1 + (dy <=> 0) * s_reach]
          c2 = sweeps[i + 1] ? [x2 - sweeps[i + 1][0] * reach, y2 - sweeps[i + 1][1] * reach] : [x2, y2 - (dy <=> 0) * s_reach]
          low, high = [y1, y2].minmax
          d << " C #{f c1[0]} #{f c1[1].clamp(low, high)}, #{f c2[0]} #{f c2[1].clamp(low, high)}, #{f x2} #{f y2}"
        end
        d
      end

      # How far down an S's handles reach, as a share of how far it drops:
      # half, for an even S, but less for one that runs far across, down to a
      # quarter at sixteen times as far, so it crosses in a straighter line
      # (Pele's +ease+).
      def ease(across, along) = (4.0 * along.abs / [across.abs, 1].max).clamp(0.25, 0.5)

      def f(n) = n.round(1)
    end
  end
end
