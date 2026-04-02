pub const default_workspace_count: usize = 4;

pub const WorkspaceState = struct {
    current: usize = 0,
    count: usize = default_workspace_count,

    pub fn clampIndex(self: WorkspaceState, index: usize) usize {
        if (self.count == 0) return 0;
        return if (index < self.count) index else self.count - 1;
    }

    pub fn activate(self: *WorkspaceState, index: usize) usize {
        self.current = self.clampIndex(index);
        return self.current;
    }

    pub fn next(self: *WorkspaceState) usize {
        if (self.count == 0) return 0;
        self.current = (self.current + 1) % self.count;
        return self.current;
    }

    pub fn previous(self: *WorkspaceState) usize {
        if (self.count == 0) return 0;
        self.current = if (self.current == 0) self.count - 1 else self.current - 1;
        return self.current;
    }
};
