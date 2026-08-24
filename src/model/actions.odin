package model

import "core:os"

Action :: enum {
	New_File,
	New_Folder,
	Rename,
	Delete,
	Copy_Path,
	Copy_Relative_Path,
	Stage_Changes,
	Change_Folder,
}

Menu_Entry :: struct {
	id:     string,
	label:  string,
	action: Action,
	danger: bool,
}

tree_menu :: proc(is_dir, in_repo: bool) -> []Menu_Entry {
	if is_dir && in_repo {
		return TREE_DIR_GIT_MENU[:]
	}
	if is_dir do return TREE_DIR_MENU[:]
	if in_repo do return TREE_FILE_GIT_MENU[:]
	return TREE_FILE_MENU[:]
}

TREE_FILE_MENU := [?]Menu_Entry{
	{id = "rename", label = "Rename", action = .Rename},
	{id = "delete", label = "Delete", action = .Delete, danger = true},
	{id = "copy-path", label = "Copy Path", action = .Copy_Path},
	{id = "copy-relative", label = "Copy Relative Path", action = .Copy_Relative_Path},
}

TREE_FILE_GIT_MENU := [?]Menu_Entry{
	{id = "stage", label = "Stage Changes", action = .Stage_Changes},
	{id = "rename", label = "Rename", action = .Rename},
	{id = "delete", label = "Delete", action = .Delete, danger = true},
	{id = "copy-path", label = "Copy Path", action = .Copy_Path},
	{id = "copy-relative", label = "Copy Relative Path", action = .Copy_Relative_Path},
}

TREE_DIR_MENU := [?]Menu_Entry{
	{id = "new-file", label = "New File", action = .New_File},
	{id = "new-folder", label = "New Folder", action = .New_Folder},
	{id = "rename", label = "Rename", action = .Rename},
	{id = "delete", label = "Delete", action = .Delete, danger = true},
	{id = "change-folder", label = "Change Folder", action = .Change_Folder},
}

TREE_DIR_GIT_MENU := [?]Menu_Entry{
	{id = "new-file", label = "New File", action = .New_File},
	{id = "new-folder", label = "New Folder", action = .New_Folder},
	{id = "stage", label = "Stage Changes", action = .Stage_Changes},
	{id = "rename", label = "Rename", action = .Rename},
	{id = "delete", label = "Delete", action = .Delete, danger = true},
	{id = "change-folder", label = "Change Folder", action = .Change_Folder},
}

validate_name :: proc(name: string) -> (string, bool) {
	if name == "" do return "name cannot be empty", false
	if name == "." || name == ".." do return "name cannot be . or ..", false
	for byte in transmute([]byte)(name) {
		if byte == 0 || os.is_path_separator(byte) do return "name cannot contain a path separator", false
	}
	return "", true
}

create_file :: proc(path: string) -> os.Error {
	file, err := os.open(path, {.Write, .Create, .Excl})
	if err != nil do return err
	os.close(file)
	return nil
}

create_folder :: proc(path: string) -> os.Error {
	return os.make_directory(path)
}

rename_entry :: proc(old_path, new_path: string) -> os.Error {
	return os.rename(old_path, new_path)
}

delete_entry :: proc(path: string) -> os.Error {
	return os.remove_all(path)
}
