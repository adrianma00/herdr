use super::App;

impl App {
    pub(crate) fn set_host_terminal_appearance_state(
        &mut self,
        appearance: Option<crate::terminal_theme::HostAppearance>,
        explicit: bool,
    ) -> bool {
        if self.state.host_terminal_appearance == appearance
            && self.state.host_terminal_appearance_explicit == explicit
        {
            return false;
        }
        self.state.host_terminal_appearance = appearance;
        self.state.host_terminal_appearance_explicit = explicit;
        self.apply_host_terminal_appearance_to_panes();
        self.refresh_effective_app_theme()
    }

    pub(crate) fn set_host_terminal_theme(
        &mut self,
        theme: crate::terminal_theme::TerminalTheme,
    ) -> bool {
        if theme == self.state.host_terminal_theme {
            return false;
        }
        self.state.host_terminal_theme = theme;
        self.apply_host_terminal_theme_to_panes();
        true
    }

    pub(super) fn refresh_effective_app_theme(&mut self) -> bool {
        let (palette, theme_name) = super::resolve_effective_theme(
            &self.state.theme_runtime,
            self.state.host_terminal_appearance,
        );
        if self.state.theme_name == theme_name && self.state.palette == palette {
            return false;
        }
        self.state.theme_name = theme_name;
        self.state.palette = palette;
        // The panes now paint different colours, so the programs inside them have to
        // learn the new defaults too (this is what follows an auto_switch).
        self.apply_host_terminal_theme_to_panes();
        self.render_dirty.request_generic();
        self.render_notify.notify_one();
        true
    }

    fn apply_host_terminal_appearance_to_panes(&self) {
        for runtime in self.terminal_runtimes.values() {
            runtime.apply_host_terminal_appearance(self.state.host_terminal_appearance);
        }
    }

    /// The default colours panes report to the programs inside them (OSC 10/11/4 and
    /// `CSI ? 997`): the host terminal's where it reported them, the active Herdr theme
    /// otherwise, so a program sees the colour its pane is actually painted with.
    fn pane_terminal_theme(&self) -> crate::terminal_theme::TerminalTheme {
        crate::terminal_theme::pane_theme_from_palette(
            &self.state.palette,
            self.state.host_terminal_theme,
        )
    }

    fn apply_host_terminal_theme_to_panes(&self) {
        let theme = self.pane_terminal_theme();
        // Panes answer OSC colour queries from this, so it has to track the theme even for
        // panes created before a client attached.
        crate::terminal_theme::set_pane_terminal_theme(theme);
        for runtime in self.terminal_runtimes.values() {
            runtime.apply_host_terminal_theme(theme);
        }

        self.render_dirty.request_generic();
        self.render_notify.notify_one();
    }
}
