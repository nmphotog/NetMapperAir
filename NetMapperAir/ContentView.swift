import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = ScannerModel()
    @State private var mode: Mode = .list

    enum Mode: String, CaseIterable, Identifiable {
        case list = "List", map = "Map"
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("NetMapper Air")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.toggle() } label: {
                        Label(model.isScanning ? "Stop" : "Scan",
                              systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise")
                    }
                }
            }
        }
        .task { model.start() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                if let i = model.interface {
                    Text("\(IPv4.string(i.address)) · \(i.cidr)")
                        .font(.headline)
                        .monospacedDigit()
                } else {
                    Text("Local Network").font(.headline)
                }
                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if model.isScanning {
                ProgressView(value: model.progress)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(model.isScanning ? "Looking for devices…" : "No devices found")
                    .foregroundStyle(.secondary)
            }
        } else if mode == .list {
            hostList
        } else {
            NetworkMapView(hosts: model.hosts)
        }
    }

    private var hostList: some View {
        List(model.hosts) { h in
            HStack(spacing: 12) {
                Image(systemName: h.symbol)
                    .font(.title3)
                    .foregroundStyle(h.isThisDevice ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(h.ip)
                        .font(.body.monospacedDigit())
                    Text(h.displayName)
                        .font(.subheadline)
                        .foregroundStyle(h.hostname == nil ? Color.secondary : Color.primary)
                        .lineLimit(1)
                }
                Spacer()
                Text(h.latency.map { String(format: "%.0f ms", $0) } ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = h.ip
                } label: {
                    Label("Copy IP Address", systemImage: "doc.on.doc")
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.refresh() }
    }
}

// MARK: - Map

struct NetworkMapView: View {
    let hosts: [DiscoveredHost]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let hub = hosts.first(where: \.isThisDevice) ?? hosts[0]
            let others = hosts.filter { $0.id != hub.id }
            let radius = max(70, min(geo.size.width, geo.size.height) / 2 - 50)
            let points: [CGPoint] = others.indices.map { i in
                let angle = Double(i) / Double(max(others.count, 1)) * 2 * .pi - .pi / 2
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }

            ZStack {
                Path { p in
                    for pt in points { p.move(to: center); p.addLine(to: pt) }
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)

                NodeView(host: hub, prominent: true).position(center)
                ForEach(Array(others.enumerated()), id: \.element.id) { i, h in
                    NodeView(host: h, prominent: false).position(points[i])
                }
            }
        }
        .padding(24)
    }
}

private struct NodeView: View {
    let host: DiscoveredHost
    let prominent: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: host.symbol)
                .font(.system(size: prominent ? 22 : 14))
                .foregroundStyle(.white)
                .frame(width: prominent ? 48 : 32, height: prominent ? 48 : 32)
                .background(Circle().fill(host.isThisDevice ? Color.accentColor : Color.gray))
            Text(host.ip)
                .font(.caption2.monospacedDigit())
            if host.hostname != nil || prominent {
                Text(host.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
        }
    }
}
