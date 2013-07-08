module HttpClient
    using HttpParser
    using HttpCommon
    using URIParser

    export URI, get, post

    ## URI Parsing

    CRLF = "\r\n"

    import .URIParser.URI

    function render(request::Request)
        join([
            request.method*" "*request.resource*" HTTP/1.1",
            map(h->(h*": "*request.headers[h]),collect(keys(request.headers))),
            "",
            request.data],CRLF)
    end

    function default_get_request(resource,host)
        Request("GET",resource,(String => String)[
            "User-Agent" => "HttpClient.jl/0.0.0",
            "Host" => host,
            "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            ],"")
    end

    ### Response Parsing


    type ResponseParserData
        current_response::Response
        sock::AsyncStream
    end

    immutable ResponseParser
        parser::Parser 
        settings::ParserSettings

        function ResponseParser(r,sock)
            parser = Parser()
            parser.data = ResponseParserData(r,sock)
            http_parser_init(parser,false)
            settings = ParserSettings(on_message_begin_cb, on_url_cb,
                              on_status_complete_cb, on_header_field_cb,
                              on_header_value_cb, on_headers_complete_cb,
                              on_body_cb, on_message_complete_cb)

            new(parser, settings)
        end
    end

    pd(p::Ptr{Parser}) = (unsafe_load(p).data)::ResponseParserData


    # Datatype Tuples for the different `cfunction` signatures used by `HttpParser`
    HTTP_CB      = (Int, (Ptr{Parser},))
    HTTP_DATA_CB = (Int, (Ptr{Parser}, Ptr{Cchar}, Csize_t,))


    # All the `HttpParser` callbacks to be run in C land
    # Each one adds data to the `Request` until it is complete
    #
    function on_message_begin(parser)
        #unsafe_ref(parser).data = Response()
        return 0
    end

    function on_url(parser, at, len)
        r = pd(parser).current_response
        r.resource = string(r.resource, bytestring(convert(Ptr{Uint8}, at),int(len)))
        return 0
    end

    function on_status_complete(parser)
        return 0
    end

    # Gather the header_field, set the field
    # on header value, set the value for the current field
    # there might be a better way to do 
    # this: https://github.com/joyent/node/blob/master/src/node_http_parser.cc#L207

    function on_header_field(parser, at, len)
        r = pd(parser).current_response
        header = bytestring(convert(Ptr{Uint8}, at))
        header_field = header[1:len]
        r.headers["current_header"] = header_field
        return 0
    end

    function on_header_value(parser, at, len)
        r = pd(parser).current_response
        s = bytestring(convert(Ptr{Uint8}, at),int(len))
        r.headers[r.headers["current_header"]] = s
        r.headers["current_header"] = ""
        return 0
    end

    function on_headers_complete(parser)
        r = pd(parser).current_response
        p = unsafe_load(parser)
        # get first two bits of p.type_and_flags
        ptype = p.type_and_flags & 0x03
        if ptype == 0
            r.method = http_method_str(convert(Int, p.method))
        elseif ptype == 1
            r.headers["status_code"] = string(convert(Int, p.status_code))
        end
        r.headers["http_major"] = string(convert(Int, p.http_major))
        r.headers["http_minor"] = string(convert(Int, p.http_minor))
        r.headers["Keep-Alive"] = string(http_should_keep_alive(parser))
        return 0
    end

    function on_body(parser, at, len)
        r = pd(parser).current_response
        r.data = string(r.data, bytestring(convert(Ptr{Uint8}, at)))
        return 0
    end

    function on_message_complete(parser)
        p = pd(parser)
        r = p.current_response
        close(p.sock)

        # delete the temporary header key
        delete!(r.headers, "current_header", nothing)
        return 0
    end

    # Turn all the callbacks into C callable functions.
    on_message_begin_cb = cfunction(on_message_begin, HTTP_CB...)
    on_url_cb = cfunction(on_url, HTTP_DATA_CB...)
    on_status_complete_cb = cfunction(on_status_complete, HTTP_CB...)
    on_header_field_cb = cfunction(on_header_field, HTTP_DATA_CB...)
    on_header_value_cb = cfunction(on_header_value, HTTP_DATA_CB...)
    on_headers_complete_cb = cfunction(on_headers_complete, HTTP_CB...)
    on_body_cb = cfunction(on_body, HTTP_DATA_CB...)
    on_message_complete_cb = cfunction(on_message_complete, HTTP_CB...)

    # `ClientParser` wraps our `HttpParser`
    # Constructed with `on_message_complete` function.
    #
    immutable ClientParser
        parser::Parser
        settings::ParserSettings

        function ClientParser(on_message_complete::Function)
            parser = Parser()
            http_parser_init(parser)
            message_complete_callbacks[parser.id] = on_message_complete

            settings = ParserSettings(on_message_begin_cb, on_url_cb,
                                      on_status_complete_cb, on_header_field_cb,
                                      on_header_value_cb, on_headers_complete_cb,
                                      on_body_cb, on_message_complete_cb)

            new(parser, settings)
        end
    end

    # Garbage collect all data associated with `parser` from the global Dicts.
    # Call this whenever closing a connection that has a `ClientParser` instance.
    #
    function clean!(parser::ClientParser)
        delete!(message_complete_callbacks, parser.parser.id, nothing)
    end

    # Passes `request_data` into `parser`
    function add_data(parser::ResponseParser, request_data::String)
        http_parser_execute(parser.parser, parser.settings, request_data)
    end

    ### API

    function get(uri::URI)
        if uri.schema != "http"
            error("Unsupported schema \"$(uri.schema)\"")
        end
        ip = Base.getaddrinfo(uri.host)
        sock = connect(ip, uri.port == 0 ? 80 : uri.port)
        resource = uri.path
        if uri.query != ""
            resource = resource*"?"*uri.query
        end
        write(sock, render(default_get_request(resource,uri.host)))
        r = Response()
        rp = ResponseParser(r,sock)
        while sock.open
            data = readavailable(sock)
            print(data)
            add_data(rp, data)
        end
        r
    end 

    get(string::ASCIIString) = get(URI(string))
end