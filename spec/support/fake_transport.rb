# A transport that never touches the network, for the client specs of every DF-e.
# Records what was sent per service and answers from a queue (strings or callables).
class FakeTransport
  Call = Struct.new(:service, :url, :operation, :xml)

  attr_reader :calls

  def initialize
    @calls = []
    @answers = Hash.new { |hash, key| hash[key] = [] }
  end

  def answer(service, *responses)
    @answers[service].concat(responses)
    self
  end

  # Replaces whatever was queued for the service.
  def replace(service, *responses)
    @answers[service] = responses
    self
  end

  def post(endpoint, xml)
    @calls << Call.new(endpoint.service, endpoint.url, endpoint.operation, xml)
    queue = @answers[endpoint.service]
    raise "no answer queued for #{endpoint.service}" if queue.empty?

    response = (queue.size > 1) ? queue.shift : queue.first
    response = response.call(xml) if response.respond_to?(:call)
    raise response if response.is_a?(Exception)

    response
  end

  def calls_to(service) = @calls.select { |call| call.service == service }
end
