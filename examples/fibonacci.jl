# Translated from the Golang Tour's select intro: https://tour.golang.org/concurrency/5
module Fibonacci

using Select
import Base.Threads: @spawn

function fibonacci(c::Channel{>:Int}, quit::Channel{>:Int})
	x, y = 0, 1
	while true
		@select begin
    		c <| x    => begin
    			x, y = y, x+y
            end
    		quit      => begin
                println("quit")
                return
            end
		end
	end
end

function main()
    @sync begin
    	c = Channel{Int}()
    	quit = Channel{Int}()
    	@spawn begin
    		for i in 0:9
    			println(take!(c))
    		end
    		put!(quit, 0)
    	end
    	fibonacci(c, quit)
    end
end

main()

end
