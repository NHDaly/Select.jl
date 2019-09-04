module Default
using Select

doevery(secs) = Channel{Int}() do ch
    while true
        sleep(secs)
        put!(ch, 1)
    end
end
doafter(secs) = Channel{Int}() do ch
    sleep(secs)
    put!(ch, 1)
end

function main()
    tick = doevery(0.1)
    boom = doafter(0.5)
    while true
        @select begin
            tick  => println("tick.")
            boom  => begin
                println("BOOM!")
                return
            end
            _  => begin
                println("    .")
                sleep(0.05)
            end
        end
    end
end

main()

end
