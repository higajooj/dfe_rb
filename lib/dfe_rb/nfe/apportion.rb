require "bigdecimal"

module DfeRb
  module Nfe
    # Spreads an invoice-level amount (freight, insurance, discount, other expenses) over the
    # items in proportion to their value, to the cent: each share is rounded down and the
    # cents left over go to the largest remainders, so the shares always add up to the amount.
    module Apportion
      # The builder name of each amount an invoice can spread, and the item tag it lands in.
      TAGS = {"freight" => "vFrete", "insurance" => "vSeg", "discount" => "vDesc", "other_expenses" => "vOutro"}.freeze
      # Where the builder keeps the amounts until the invoice is resolved; never written.
      KEY = "#apportion"

      module_function

      # `amount` split by `weights` (each item's vProd), as BigDecimals with 2 places. Equal
      # shares when every weight is zero.
      def call(amount, weights)
        return [] if weights.empty?

        cents = (Totals.money(amount) * 100).to_i
        weights = weights.map { |weight| Totals.number(weight) }
        weights = weights.map { BigDecimal(1) } unless weights.any?(&:positive?)
        total = weights.sum
        exact = weights.map { |weight| cents * weight / total }
        shares = exact.map(&:floor)
        leftover = cents - shares.sum
        order = exact.each_index.sort_by { |index| [-(exact[index] - shares[index]), index] }
        order.first(leftover).each { |index| shares[index] += 1 }
        shares.map { |share| BigDecimal(share) / 100 }
      end

      # Sets each amount of `amounts` ({"vFrete" => "50.00"}) on the resolved <det> hashes.
      # An item that already has the value keeps it and takes no share; a zero share is left
      # out, as the layout doesn't take 0.00.
      def apply(det, amounts)
        amounts.each do |tag, amount|
          open = det.select { |item| item.dig("prod", tag).nil? }
          shares = call(amount, open.map { |item| item.dig("prod", "vProd") })
          open.zip(shares) { |item, share| item["prod"][tag] = share if share.positive? }
        end
      end
    end
  end
end
