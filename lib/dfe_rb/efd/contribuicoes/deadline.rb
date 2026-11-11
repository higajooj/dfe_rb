module DfeRb
  module Efd
    module Contribuicoes
      # When a month's file is due: the 10th business day of the second month after it
      # (IN RFB 1.252/2012). An original file delivered later carries 0900 (Guia
      # Prático, 0900). Business days are weekdays but the national holidays
      # (Lei 662/1949, Lei 6.802/1980, Lei 14.759/2023) and Good Friday; a state's or a
      # city's own holidays aren't counted.
      module Deadline
        FIXED_HOLIDAYS = [[1, 1], [4, 21], [5, 1], [9, 7], [10, 12], [11, 2], [11, 15], [12, 25]].freeze

        module_function

        # The last day to deliver the file of the month that starts on (or contains) month.
        def for(month)
          day = Date.new(month.year, month.month, 1) >> 2
          count = 0
          loop do
            count += 1 if business_day?(day)
            return day if count == 10

            day += 1
          end
        end

        # Delivered on a day after the deadline.
        def late?(month, on:) = on > self.for(month)

        def business_day?(day) = !day.saturday? && !day.sunday? && !holidays(day.year).include?(day)

        def holidays(year)
          days = FIXED_HOLIDAYS.map { |month, day| Date.new(year, month, day) }
          days << Date.new(year, 11, 20) if year >= 2024
          days << easter(year) - 2
        end

        # Easter Sunday (the anonymous Gregorian algorithm).
        def easter(year)
          a = year % 19
          b, c = year.divmod(100)
          d, e = b.divmod(4)
          f = (b + 8) / 25
          g = (b - f + 1) / 3
          h = (19 * a + b - d - g + 15) % 30
          i, k = c.divmod(4)
          l = (32 + 2 * e + 2 * i - h - k) % 7
          m = (a + 11 * h + 22 * l) / 451
          month, day = (h + l - 7 * m + 114).divmod(31)
          Date.new(year, month, day + 1)
        end
      end
    end
  end
end
