// SignalLinkPreviewParser.xpc: parses link-preview HTML (from SignalLinkPreviewFetcher.xpc) and nothing else. Signed with App
// Sandbox plus the Seatbelt rules of Sandbox/SignalLinkPreviewParser.sb (Tools/build-app.sh puts
// them in its entitlements); it refuses to serve unless that profile is in force.

import Foundation
import LinkPreviewParser
import MediaXPCInterface

ServiceSandbox.requireConfinement("SignalLinkPreviewParser")
// The app may only ask for the HTML endpoint; HTML comes from the fetcher alone.
let service = EndpointService(requirement: XPCPeer.required(.fetcher, by: "SignalLinkPreviewParser"), LinkPreviewXPCHandler())
XPCServer.serve(LinkPreviewParserClient.serviceName, requirement: XPCPeer.required(.app, by: "SignalLinkPreviewParser"), service)
