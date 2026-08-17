# Opens N concurrent connections to a host:port, sends a complete HTTP request
# on each, and holds them open without reading the response.
#
# Holding matters: the customer incident was not a burst that drained. Amazon
# retries webhooks, Cloudflare retries, and tracking pixels keep arriving, so
# the descriptor pressure was continuous for 31 minutes and nothing ever got a
# chance to free up. A flood that releases immediately does not reproduce that.
#
# Runs inside a container from the app image so the suite does not need Ruby on
# the host.
require 'socket'

host  = ARGV[0]
port  = ARGV[1].to_i
count = ARGV[2].to_i
hold  = ARGV[3].to_i

socks = []
count.times do
  begin
    s = TCPSocket.new(host, port)
    s.write("GET /up HTTP/1.1\r\nHost: #{host}\r\n\r\n")
    socks << s
  rescue StandardError => e
    warn "flood stopped at #{socks.size} sockets: #{e.class}"
    break
  end
end

puts "HELD #{socks.size}"
$stdout.flush

sleep hold

socks.each { |s| s.close rescue nil }
puts 'RELEASED'
