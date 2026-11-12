// SignalGifSearch.xpc: GIF search and files from Giphy, through Signal's content proxy, and
// nothing else. Signed with App Sandbox (outgoing network only) plus the Seatbelt rules of
// Sandbox/SignalGifSearch.sb (no user files, no writes, no processes); it refuses to serve
// unless they are in force. Giphy's JSON is decoded here; the app gets validated results and
// MP4 bytes, which only the media decoder reads.

import Foundation
import GifSearch
import MediaXPCInterface
import WebFetch

ServiceSandbox.requireConfinement("SignalGifSearch", systemFiles: true)
let handler = GifSearchXPCHandler(giphy: GiphyClient(transport: URLSessionWebTransport(proxy: .signal)))
XPCServer.serve(GifSearchClient.serviceName, requirement: XPCPeer.required(.app, by: "SignalGifSearch"), handler)
