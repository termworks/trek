package settings

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_preferences_round_trip :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "trek-settings-*", context.allocator)
	testing.expect(t, err == nil)
	defer { _ = os.remove_all(root); delete(root) }
	preferences: Preferences
	preferences_init(&preferences, root)
	delete(preferences.icons)
	preferences.icons = strings.clone("material")
	preferences.hidden = true
	delete(preferences.start_tab)
	preferences.start_tab = strings.clone("graph")
	expanded, _ := filepath.join([]string{root, "src"}, context.allocator)
	preferences_set_expanded(&preferences, root, []string{expanded})
	testing.expect(t, preferences_save(&preferences))
	preferences_destroy(&preferences)
	loaded: Preferences
	preferences_init(&loaded, root)
	defer preferences_destroy(&loaded)
	testing.expect(t, preferences_load(&loaded))
	testing.expect_value(t, loaded.icons, "material")
	testing.expect(t, loaded.hidden)
	testing.expect_value(t, loaded.start_tab, "graph")
	paths := preferences_expanded(&loaded, root)
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 do testing.expect_value(t, paths[0], expanded)
	delete(expanded)
}

@(test)
test_preferences_reject_invalid_theme :: proc(t: ^testing.T) {
	preferences: Preferences
	preferences_init(&preferences, "/tmp/trek-settings-invalid")
	defer preferences_destroy(&preferences)
	delete(preferences.icons)
	preferences.icons = strings.clone("unknown")
	preferences_validate(&preferences)
	testing.expect_value(t, preferences.icons, "")
}
