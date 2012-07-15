// TODO: catch exceptions on futures
// TODO: json buffering under load

#import("dart:isolate");
#import("dart:io");
#import("dart:json");
#import("dart:uri");

final HOST = "0.0.0.0";
final TCP_PORT = 5280;
final HTTP_PORT = 9001;
final API_URL = "localhost";
final API_PORT = 9292;
final API_REQUEST_TIMEOUT = 3*1000;
final HTTP_REQUEST_TO_API_TIMEOUT = 2000;
final PLUG_TIMEOUT = 31*1000; // 31
final KEEP_ALIVE_INTERVAL = 11*1000; // 11

Map tcp_conns; // id -> socket conn (for accessing a particular tcp conn)
Map pending_res; // rid -> callback (for responding to requests)
Map timers; // id -> stopwatch (for keep alives)
Map<String,Timer> request_timers;

class TCPServer {
  ServerSocket server;
  
  TCPServer(host,port) {
    print("Starting TCP server on ${host}:${port}...");
    server = new ServerSocket(host,port,0);
    server.onConnection = handleTCPConnection;
  }
  
  void handleTCPConnection(Socket conn) {
    StringInputStream client = new StringInputStream(conn.inputStream);
    OutputStream clientOut = conn.outputStream;
    var id = null;
    var stopwatch = new Stopwatch.start(); // used for keep alives
    
    client.onClosed = () {
      print("client conn closed");  
      if(id!=null && tcp_conns[id]!=null) {
        tcp_conns.remove(id);
      }
    };
    client.onData = () {
      String data = client.read();
      
      Map result = JSON.parse(data);
      if(result!=null) {
        stopwatch.reset(); // reset keep alives on each message
        if(result['m']!=null) {
          var m = result['m'];
          
          if(m=='keep_alive') {
            // 1. Keep Alive responder
            
            var url = "/private/keep_alive?id=${id}&status=success";
            // TODO power & auto-shutdown
            
            Future<String> response = makeHTTPRequest(url);
            response.then( (value){
              print("API response to keepalive: $value"); 
            });
            
          }
          else if(result['rid']!=null) {
            // 2. Response to message from HTTP interface
            
            var rid = result['rid'];
            print("API Response: ${rid},${data})");
            
            if(request_timers.containsKey(rid)) {
              request_timers.remove(rid).cancel();
            }
            
            if(pending_res[rid]!=null) {
              print("API Response has matching callback");
              // build response
              Map output= {
                     "rid":rid,
                     "rtime":'0',
                     "response":result
              };
              var completer = pending_res[rid];
              completer.complete(JSON.stringify(output)); // this should handle callback
            }
          }
          else {
            // 3. Message from plug
            
            var route = null;
            if(m=="connect_device") {
              route = "/private/connect_plug";
              if(result['id']!=null) {
                id = result['id'];
                tcp_conns[id] = conn;
                timers[id] = stopwatch;
              }
            }
            else if(m=="add") { // TODO duplicate code of above except for route!!!
              route = "/private/create_plug";
              if(result['id']!=null) {
                id = result['id'];
                tcp_conns[id] = conn;
                timers[id] = stopwatch;
              }
            }
            else if(m=="upload_power_data") {
              route = "/private/upload_power_data";
            }
            else if(m=="set") {
              route = "/private/update_plug";
            }
            else if(m=="resetfromplug") {
              route = "/private/reset_plug";
            }
            
            var url = "${route}?id=${id}";
            result.forEach( (key,value) => url = "$url&$key=${encodeUri(value)}" );
            //print("RESULT url: $url");
            
            Future<String> response = makeHTTPRequest(url);
            response.then( (value)=>clientOut.writeString(value) );
          }
        }
      }
      else {
        clientOut.writeString("{\"success\":\"false\",\"response\":\"no m parameter\"}");
      }
    };
    
  }
}

// External HTTP Request
Future<String> makeHTTPRequest(String route) {
  Completer completer = new Completer();
  HttpClient httpClient = new HttpClient();
  HttpClientConnection conn = httpClient.get(API_URL, API_PORT, route);
  conn.onResponse = (HttpClientResponse response) {
    StringInputStream stream = new StringInputStream(response.inputStream);
    StringBuffer body = new StringBuffer();
    stream.onData = () => body.add(stream.read());
    stream.onClosed = () {
      completer.complete(body.toString());
    };
  };
  conn.onError = (err) {
    print("makeHTTPRequest: $err");
    completer.complete(err.toString());
  };
  return completer.future;
}

// Callback for http requests (used in tcp handler)
Future<String> TCPCommFutureFunc(rid,id,json) {
  print("rid:$rid, id:$id, json:$json");
  
  Completer completer = new Completer();
  
  if(tcp_conns[id]!=null){
    var conn = tcp_conns[id];
    pending_res[rid] = completer;
    
    //print("---> plug=${id}: ${json}");
    conn.outputStream.writeString(json);
    // return value via completer.complete(val) in the tcp receive data event up above
  } else {
    request_timers.remove(rid).cancel();
    var msg = '{"success":"false","response":"plug not found"}';
    completer.complete(msg);
  }
  return completer.future;
}

void httpRequestReceivedHandler(HttpRequest request, HttpResponse response) {
  print("Request: ${request.method} ${request.uri}");
  var parms = request.queryParameters;
  
  var rid = parms['rid'];
  var id = parms['id'];
  var json = parms['json'];
  
  if(rid!=null && id!=null && json!=null) {
    request_timers[rid] = new Timer(API_REQUEST_TIMEOUT,(timer) {
      request_timers.remove(rid);
      response.headers.set(HttpHeaders.CONTENT_TYPE, "application/json; charset=UTF-8");
      response.outputStream.writeString('{"success":"false","response":"request to plug=$id timed out"}');
      response.outputStream.close();
    });
    
    Future<String> tcp_response = TCPCommFutureFunc(rid,id,json);
    tcp_response.then( (value){
      response.headers.set(HttpHeaders.CONTENT_TYPE, "application/json; charset=UTF-8");
      response.outputStream.writeString(value.toString());
      response.outputStream.close();
    });
  } else { // GET /favicon.ico
    response.outputStream.close();
  }
  
}

void main() {
  tcp_conns = {};
  pending_res = {};
  timers = {};
  request_timers = {};
  
  HttpServer httpserver = new HttpServer();
  httpserver.listen(HOST, HTTP_PORT);
  httpserver.defaultRequestHandler = httpRequestReceivedHandler;
  TCPServer tcpserver = new TCPServer(HOST,TCP_PORT);
  
  // We send all active plugs (not just tcp connections, but plugs
  // that have verified themselves and all that) keep alive messages
  var keep_alive_sender = new Timer.repeating(KEEP_ALIVE_INTERVAL, (Timer t) {
    tcp_conns.forEach((id,conn) {
      print('sending keep alive to plug=$id');
      
      if(timers[id]!=null){
        var elapsed = timers[id].elapsedInMs();
      
        print ('elapsed = $elapsed');
        if(elapsed<PLUG_TIMEOUT) { // plug hasn't timed out
          print("last msg from plug $id conn: $elapsed");
          var msg = {'m':'keep_alive'};
          conn.outputStream.writeString(JSON.stringify(msg));
        }
        else { // plug has timed out 
          print("plug $id has timed out: $elapsed");
          var route = "/private/disconnect_plug?id=$id";
          Future<String> response = makeHTTPRequest(route);
          response.then( (value) {
            print("Plug timeout api call: $value");
          });
          conn.close();
        }
      }
    });
  });
}
