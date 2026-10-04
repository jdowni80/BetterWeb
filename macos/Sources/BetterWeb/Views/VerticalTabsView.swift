import SwiftUI

/// Apheleia's 240pt vertical tab sidebar: pinned tabs, pinned groups, divider,
/// groups, tabs, and the "+ Tab / + Group" footer. Tabs and groups drag to reorder.
struct VerticalTabsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var endTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            WindowDragArea()
                .frame(height: ApheleiaTheme.trafficLightPad)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.pinnedUngroupedTabs) { tab in
                        TabRowView(tab: tab)
                    }
                    ForEach(model.pinnedGroups) { group in
                        GroupSectionView(group: group)
                    }

                    if !model.pinnedUngroupedTabs.isEmpty || !model.pinnedGroups.isEmpty {
                        Rectangle()
                            .fill(ApheleiaTheme.border)
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    ForEach(model.unpinnedGroups) { group in
                        GroupSectionView(group: group)
                    }
                    ForEach(model.unpinnedUngroupedTabs) { tab in
                        TabRowView(tab: tab)
                    }

                    // Drop here to move a tab to the end of the ungrouped list.
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .overlay(alignment: .top) {
                            if endTargeted {
                                Rectangle().fill(ApheleiaTheme.dropIndicator).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.newTab() }
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap(DragPayload.tab) else { return false }
                            model.moveTab(id, before: nil, inGroup: nil)
                            return true
                        } isTargeted: { endTargeted = $0 }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)

            HStack(spacing: 8) {
                FooterButton(title: "+ Tab") { model.newTab() }
                FooterButton(title: "+ Group") { model.newGroup() }
            }
            .padding(8)
        }
        .frame(width: ApheleiaTheme.sidebarWidth)
        .background(ApheleiaTheme.bgSecondary)
        .overlay(alignment: .trailing) {
            Rectangle().fill(ApheleiaTheme.border).frame(width: 1)
        }
    }
}

enum DragPayload {
    static func tab(_ id: UUID) -> String { "tab:\(id.uuidString)" }
    static func group(_ id: UUID) -> String { "group:\(id.uuidString)" }

    static func tab(_ payload: String) -> UUID? {
        payload.hasPrefix("tab:") ? UUID(uuidString: String(payload.dropFirst(4))) : nil
    }

    static func group(_ payload: String) -> UUID? {
        payload.hasPrefix("group:") ? UUID(uuidString: String(payload.dropFirst(6))) : nil
    }
}

private struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(ApheleiaTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(ApheleiaTheme.border, in: RoundedRectangle(cornerRadius: 4))
                .opacity(hovering ? 0.8 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct GroupSectionView: View {
    @EnvironmentObject private var model: AppModel
    let group: TabGroup
    @State private var draftName = ""
    @State private var hovering = false
    @State private var targeted = false
    @FocusState private var nameFocused: Bool

    private var editing: Bool { model.editingGroupID == group.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if group.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(ApheleiaTheme.pin)
                }
                Text("▶")
                    .font(.system(size: 8))
                    .rotationEffect(.degrees(group.collapsed ? 0 : 90))
                    .animation(.easeOut(duration: 0.12), value: group.collapsed)

                if editing {
                    TextField("Group name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .background(ApheleiaTheme.border, in: RoundedRectangle(cornerRadius: 3))
                        .focused($nameFocused)
                        .onSubmit { model.renameGroup(group.id, to: draftName) }
                        .onExitCommand { model.editingGroupID = nil }
                        .onAppear {
                            draftName = group.name
                            DispatchQueue.main.async { nameFocused = true }
                        }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused && editing { model.renameGroup(group.id, to: draftName) }
                        }
                } else {
                    Text(group.name)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if hovering && !editing {
                    HStack(spacing: 4) {
                        Text("(\(group.tabIDs.count))")
                            .foregroundStyle(ApheleiaTheme.textFaint)
                        RowIconButton(systemName: group.pinned ? "pin.slash" : "pin", help: group.pinned ? "Unpin" : "Pin") {
                            model.toggleGroupPinned(group.id)
                        }
                        RowIconButton(systemName: "xmark", help: "Close group") {
                            model.closeGroup(group.id)
                        }
                    }
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(ApheleiaTheme.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minHeight: 26)
            .background(hovering || targeted ? ApheleiaTheme.bgHover : Color.clear)
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(ApheleiaTheme.dropIndicator).frame(height: 2) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                TapGesture(count: 2).onEnded {
                    draftName = group.name
                    model.editingGroupID = group.id
                }
                .exclusively(before: TapGesture(count: 1).onEnded {
                    if !editing { model.toggleGroupCollapsed(group.id) }
                })
            )
            .draggable(DragPayload.group(group.id)) {
                Text(group.name)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(6)
                    .background(ApheleiaTheme.bgActiveTab, in: RoundedRectangle(cornerRadius: 4))
            }
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                if let tabID = DragPayload.tab(payload) {
                    model.moveTab(tabID, before: nil, inGroup: group.id)
                    return true
                }
                if let groupID = DragPayload.group(payload) {
                    model.moveGroup(groupID, before: group.id)
                    return true
                }
                return false
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button("New Tab in Group") { model.newTab(inGroup: group.id) }
                Button("Rename") {
                    draftName = group.name
                    model.editingGroupID = group.id
                }
                Button(group.pinned ? "Unpin Group" : "Pin Group") { model.toggleGroupPinned(group.id) }
                Button(group.collapsed ? "Expand" : "Collapse") { model.toggleGroupCollapsed(group.id) }
                Divider()
                Button("Ungroup Tabs") { model.ungroup(group.id) }
                Button("Close Group", role: .destructive) { model.closeGroup(group.id) }
            }

            if !group.collapsed {
                ForEach(model.orderedTabs(ids: group.tabIDs)) { tab in
                    TabRowView(tab: tab, groupID: group.id)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

private struct TabRowView: View {
    @EnvironmentObject private var model: AppModel
    let tab: BrowserTab
    var groupID: UUID? = nil

    @State private var hovering = false
    @State private var targeted = false

    private var selected: Bool { tab.id == model.activeTabID }
    private var rt: TabRuntime { model.runtime[tab.id] ?? TabRuntime() }

    var body: some View {
        HStack(spacing: 8) {
            if tab.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(ApheleiaTheme.pin)
            }
            if rt.loading && tab.pageURL != nil {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else if tab.pageURL != nil {
                FaviconView(host: tab.faviconHost)
            } else if let icon = contentIcon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(ApheleiaTheme.textMuted)
                    .frame(width: 16, height: 16)
            }

            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(selected ? Color.white : ApheleiaTheme.textSecondary)
        .padding(.leading, groupID != nil ? 24 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? ApheleiaTheme.bgActiveTab : (hovering ? ApheleiaTheme.bgHover : Color.clear))
        .overlay(alignment: .trailing) {
            if hovering {
                HStack(spacing: 4) {
                    RowIconButton(systemName: tab.pinned ? "pin.slash" : "pin", help: tab.pinned ? "Unpin" : "Pin") {
                        model.togglePin(tab.id)
                    }
                    if !tab.pinned {
                        RowIconButton(systemName: "xmark", help: "Close tab (⌘W)") {
                            model.closeTab(tab.id)
                        }
                    }
                }
                .padding(.leading, 6)
                .background(selected ? ApheleiaTheme.bgActiveTab : ApheleiaTheme.bgHover)
                .padding(.trailing, 8)
            }
        }
        .overlay(alignment: .top) {
            if targeted { Rectangle().fill(ApheleiaTheme.dropIndicator).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .help(tab.title.isEmpty ? "New Tab" : tab.title)
        .onTapGesture { model.selectTab(tab.id) }
        .onHover { hovering = $0 }
        .draggable(DragPayload.tab(tab.id)) {
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: 220)
                .background(ApheleiaTheme.bgActiveTab, in: RoundedRectangle(cornerRadius: 4))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(DragPayload.tab) else { return false }
            model.moveTab(id, before: tab.id, inGroup: groupID)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button(tab.pinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab.id) }
            if let url = tab.pageURL {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                Button("Duplicate Tab") { model.openInNewTab(url: url, from: tab.id, activate: true) }
            }
            Menu("Move to Group") {
                ForEach(model.groups) { group in
                    Button(group.name) { model.moveTabToGroup(tab.id, groupID: group.id) }
                        .disabled(group.id == groupID)
                }
                if !model.groups.isEmpty { Divider() }
                Button("New Group") {
                    model.selectTab(tab.id)
                    model.newGroup()
                }
            }
            if groupID != nil {
                Button("Remove from Group") { model.moveTabToGroup(tab.id, groupID: nil) }
            }
            Divider()
            Button("Close Tab") { model.closeTab(tab.id, force: true) }
        }
    }

    private var contentIcon: String? {
        switch tab.content {
        case .search: return "magnifyingglass"
        case .history: return "clock"
        case .settings: return "gearshape"
        default: return nil
        }
    }
}

private struct RowIconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ApheleiaTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? ApheleiaTheme.rowButtonHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
