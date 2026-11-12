// SignalLinkPreviewFetcher.xpc: fetches link-preview pages and images from the web, and nothing
// else. Signed with App Sandbox (outgoing network only) plus the Seatbelt rules of
// Sandbox/SignalLinkPreviewFetcher.sb (no user files, no writes, no processes); it refuses to
// serve unless they are in force. Pages go to SignalLinkPreviewParser.xpc through the endpoint
// the app hands over with each fetch; images go back to the app unread.

import Foundation
import LinkPreviewFetcher
import MediaXPCInterface
import WebFetch

ServiceSandbox.requireConfinement("SignalLinkPreviewFetcher", systemFiles: true)
// Straight to the site, and only to sites on the public internet (WebFetch/DestinationPolicy.swift).
let handler = LinkPreviewFetcherXPCHandler(transport: PublicDestinationTransport(URLSessionWebTransport(proxy: .direct)),
                                           parserPeer: XPCPeer.required(.parser, by: "SignalLinkPreviewFetcher"))
XPCServer.serve(LinkPreviewFetcherClient.serviceName, requirement: XPCPeer.required(.app, by: "SignalLinkPreviewFetcher"), handler)
