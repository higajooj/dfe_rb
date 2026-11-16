module DfeRb
  module Nfe
    # What NT 2023.002 v1.02 (October 2026) switches off at SEFAZ, and when. Every date is
    # compared with the clock of the request, or with the notes' dhEmi, in Brasília time
    # like the other rules' dates.
    module Retirements
      # RV I01a: the inutilização web service of AC, BA and SP is gone (Ajustes SINIEF 38/2026
      # and 40/2026), in homologação and in production alike. SEFAZ answers 998 "Serviço
      # Desativado" or HTTP 404.
      INUTILIZATION_OFF_STATES = %w[AC BA SP].freeze
      INUTILIZATION_OFF_SINCE = Time.new(2026, 11, 11, 0, 0, 0, "-03:00")
      INUTILIZATION_AJUSTES = "Ajustes SINIEF 38/2026 and 40/2026"

      # RV GAP03a-6 (models 55 and 65): a request for asynchronous authorization (indSinc 0) is
      # rejected with 129, so a lot holds one note and is answered at once. Homologação
      # implements it by 01/02/2027, production on 05/04/2027, which is the day SEFAZ starts
      # to reject it there.
      ASYNC_LOT_ENDS = {
        Environment::HOMOLOGACAO => Time.new(2027, 2, 1, 0, 0, 0, "-03:00"),
        Environment::PRODUCTION => Time.new(2027, 4, 5, 0, 0, 0, "-03:00")
      }.freeze

      module_function

      # Whether `uf`'s inutilização service is off at `now` (RV I01a).
      def inutilization_off?(uf, now)
        INUTILIZATION_OFF_STATES.include?(States.abbreviation(uf)) && now >= INUTILIZATION_OFF_SINCE
      end

      # What a refused request says. `answer` is what SEFAZ answered when the service
      # itself said it is off ("rej. 998" or "HTTP 404"), nil when the request wasn't sent.
      def inutilization_message(uf, answer: nil)
        state = States.abbreviation(uf)
        since = INUTILIZATION_OFF_SINCE.strftime("%d/%m/%Y")
        if INUTILIZATION_OFF_STATES.include?(state)
          lead = answer ? "SEFAZ #{state} answered #{answer}: " : "nothing was sent: "
          "#{lead}the inutilização service of #{state} is switched off since #{since} (#{INUTILIZATION_AJUSTES}; " \
            "RV I01a, rej. 998; NT 2023.002 v1.02), so a skipped number can't be inutilized there"
        else
          "SEFAZ #{state} answered #{answer}, which is how a state switches the inutilização service off (RV I01a, " \
            "NT 2023.002 v1.02); AC, BA and SP have since #{since} (#{INUTILIZATION_AJUSTES}). If #{state} hasn't, " \
            "check the endpoint"
        end
      end

      # The day asynchronous lots end for `environment`.
      def async_lot_ends(environment) = ASYNC_LOT_ENDS.fetch(Environment.normalize(environment))

      # Whether a lot of several notes is refused, as of `moments` (the clock of the request and
      # the notes' dhEmi): any of them on or after the day it ends.
      def async_lot_ended?(environment, moments)
        ends = async_lot_ends(environment)
        moments.compact.any? { |moment| moment >= ends }
      end

      def async_lot_message(environment, count)
        "a lot of #{count} notes is an asynchronous request (indSinc 0), which SEFAZ rejects since " \
          "#{async_lot_ends(environment).strftime("%d/%m/%Y")} in #{environment} (RV GAP03a-6, rej. 129; NT 2023.002 v1.02): " \
          "authorize each note in its own call (client.authorize(note) answers at once)"
      end
    end
  end
end
