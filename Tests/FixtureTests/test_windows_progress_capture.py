"""Reject unrelated/hidden operation evidence and preserve byte-level source comparisons."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('windows_capture', Path(__file__).parents[2] / 'scripts/capture-windows-reference.py')
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


def card(title, controls, visible='False'):
    row = ET.Element('ListItem', IsOffscreen=visible)
    ET.SubElement(row, 'Text', AutomationId='StatusCenterItemHeaderTextBlock', Name=title, IsOffscreen='False')
    for identifier in controls:
        ET.SubElement(row, 'Button', AutomationId=identifier, IsOffscreen='False')
    return row


def tree(*rows):
    root = ET.Element('Window')
    listing = ET.SubElement(root, 'List', AutomationId='StatusCenterItemsListView', IsOffscreen='False')
    listing.extend(rows)
    return ET.ElementTree(root)


class ProgressEvidenceTests(unittest.TestCase):
    def test_active_requires_matching_visible_destination_and_progress(self):
        row = card('Copying 1 item to "Workshop"', ['MoreOptionsButton', 'MainProgressBar'])
        self.assertIs(capture.operation_copy_card(tree(row), 'Workshop'), row)
        self.assertIsNone(capture.operation_copy_card(tree(row), 'Different'))
        row.set('IsOffscreen', 'True')
        self.assertIsNone(capture.operation_copy_card(tree(row), 'Workshop'))

    def test_completed_and_unrelated_sibling_controls_cannot_prove_active(self):
        completed = card('Copied 1 item to "Workshop"', ['CloseItemButton'])
        unrelated = card('Copying 1 item to "Different"', ['MoreOptionsButton', 'MainProgressBar'])
        self.assertIsNone(capture.operation_copy_card(tree(completed, unrelated), 'Workshop'))
        self.assertIsNone(capture.operation_copy_card(tree(card('Copying 1 item to "Workshop"', ['MoreOptionsButton'])), 'Workshop'))

    def test_cancelled_requires_terminal_controls_on_the_same_card(self):
        row = card('Cancelled copying 1 item to "Workshop"', ['CloseItemButton'])
        self.assertIs(capture.operation_copy_card(tree(row), 'Workshop', cancelled=True), row)
        ET.SubElement(row, 'Button', AutomationId='MoreOptionsButton', IsOffscreen='False')
        self.assertIsNone(capture.operation_copy_card(tree(row), 'Workshop', cancelled=True))
        self.assertIsNone(capture.operation_copy_card(tree(card('Copied 1 item to "Workshop"', ['CloseItemButton'])), 'Workshop', cancelled=True))

    def test_manifest_detects_content_and_name_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            item = root / '한글.bin'
            item.write_bytes(b'abc')
            before = capture.transfer_fixture_manifest(root)
            self.assertEqual((before['files'], before['bytes']), (1, 3))
            item.write_bytes(b'xyz')
            self.assertNotEqual(capture.transfer_fixture_manifest(root)['sha256'], before['sha256'])
            item.write_bytes(b'abc')
            item.rename(root / 'renamed.bin')
            self.assertNotEqual(capture.transfer_fixture_manifest(root)['sha256'], before['sha256'])

    def test_empty_directory_rename_and_type_change_cannot_preserve_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / 'Workshop'
            child.mkdir()
            before = capture.transfer_fixture_manifest(root)
            self.assertEqual((before['files'], before['directories'], before['bytes']), (0, 1, 0))
            renamed = root / 'Renamed'
            child.rename(renamed)
            self.assertNotEqual(capture.transfer_fixture_manifest(root)['sha256'], before['sha256'])
            renamed.rename(child)
            self.assertEqual(capture.transfer_fixture_manifest(root), before)
            child.rmdir()
            child.touch()
            after = capture.transfer_fixture_manifest(root)
            self.assertEqual((after['files'], after['directories'], after['bytes']), (1, 0, 0))
            self.assertNotEqual(after['sha256'], before['sha256'])

    def test_missing_or_linked_fixture_root_is_not_an_empty_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for unavailable in [root / 'missing', root / 'linked']:
                if unavailable.name == 'linked':
                    unavailable.symlink_to(root, target_is_directory=True)
                with self.subTest(root=unavailable.name), self.assertRaises(RuntimeError):
                    capture.transfer_fixture_manifest(unavailable)

    def test_manifest_rejects_links_instead_of_reading_their_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'link').symlink_to('/does-not-exist')
            with self.assertRaisesRegex(RuntimeError, 'symbolic link'):
                capture.transfer_fixture_manifest(root)


class RenameEvidenceTests(unittest.TestCase):
    def dialog(self, enabled=False, warning=False):
        root = ET.Element('Window')
        ET.SubElement(root, 'Edit', AutomationId='FileNameBox', IsOffscreen='False')
        ET.SubElement(root, 'Button', AutomationId='PrimaryButton', Name='Rename', IsEnabled=str(enabled), IsOffscreen='False')
        ET.SubElement(root, 'Button', AutomationId='SecondaryButton', Name='Cancel', IsEnabled='True', IsOffscreen='False')
        if warning:
            ET.SubElement(root, 'Text', Name='The item name specified is invalid', IsOffscreen='False')
        return ET.ElementTree(root)

    def test_disabled_does_not_prove_invalid_without_visible_warning(self):
        self.assertTrue(capture.bulk_rename_controls(self.dialog(), enabled=False))
        self.assertFalse(capture.bulk_rename_controls(self.dialog(), enabled=False, invalid=True))
        self.assertTrue(capture.bulk_rename_controls(self.dialog(warning=True), enabled=False, invalid=True))

    def test_valid_requires_enabled_rename_and_dismissed_warning(self):
        self.assertTrue(capture.bulk_rename_controls(self.dialog(enabled=True), enabled=True))
        self.assertFalse(capture.bulk_rename_controls(self.dialog(enabled=True, warning=True), enabled=True))
        self.assertFalse(capture.bulk_rename_controls(self.dialog(), enabled=True))

    def test_hidden_or_ambiguous_dialog_controls_do_not_prove_state(self):
        result = self.dialog()
        editor = next(element for element in result.iter() if element.get('AutomationId') == 'FileNameBox')
        editor.set('IsOffscreen', 'True')
        self.assertFalse(capture.bulk_rename_controls(result, enabled=False))
        editor.set('IsOffscreen', 'False')
        ET.SubElement(result.getroot(), 'Edit', AutomationId='FileNameBox', IsOffscreen='False')
        self.assertFalse(capture.bulk_rename_controls(result, enabled=False))


class EditorFocusEvidenceTests(unittest.TestCase):
    def test_another_focused_control_cannot_authorize_editor_input(self):
        root = ET.Element('Window')
        editor = ET.SubElement(root, 'Edit', AutomationId='PART_TextBox', IsOffscreen='False', IsEnabled='True', HasKeyboardFocus='False')
        ET.SubElement(root, 'Edit', AutomationId='InlineRename', IsOffscreen='False', IsEnabled='True', HasKeyboardFocus='True')
        self.assertFalse(capture.editor_has_keyboard_focus(ET.ElementTree(root), 'PART_TextBox'))
        editor.set('HasKeyboardFocus', 'True')
        self.assertTrue(capture.editor_has_keyboard_focus(ET.ElementTree(root), 'PART_TextBox'))
        editor.set('IsOffscreen', 'True')
        self.assertFalse(capture.editor_has_keyboard_focus(ET.ElementTree(root), 'PART_TextBox'))

    def test_ambiguous_and_disabled_editors_reject_input(self):
        root = ET.Element('Window')
        editor = ET.SubElement(root, 'Edit', AutomationId='FileNameBox', IsOffscreen='False', IsEnabled='False', HasKeyboardFocus='True')
        self.assertFalse(capture.editor_has_keyboard_focus(ET.ElementTree(root), 'FileNameBox'))
        editor.set('IsEnabled', 'True')
        ET.SubElement(root, 'Edit', AutomationId='FileNameBox', IsOffscreen='False', IsEnabled='True', HasKeyboardFocus='True')
        self.assertFalse(capture.editor_has_keyboard_focus(ET.ElementTree(root), 'FileNameBox'))


class ArchiveCreationEvidenceTests(unittest.TestCase):
    def archive_tree(self, enabled=True):
        root = ET.Element('Window', Name='Create archive', IsOffscreen='False')
        for identifier in ('FileNameBox', 'FileFormatSelector', 'CompressionLevelSelector', 'PrimaryButton', 'CloseButton'):
            ET.SubElement(root, 'Control', AutomationId=identifier, IsOffscreen='False',
                          IsEnabled=str(enabled) if identifier == 'PrimaryButton' else 'True',
                          Name={'PrimaryButton': 'Create', 'CloseButton': 'Cancel'}.get(identifier, ''))
        return ET.ElementTree(root)

    def test_valid_and_empty_states_require_the_archive_dialog(self):
        self.assertTrue(capture.archive_creation_controls(self.archive_tree(), enabled=True))
        empty = self.archive_tree(False)
        self.assertTrue(capture.archive_creation_controls(empty, enabled=False))
        self.assertFalse(capture.archive_creation_controls(empty, enabled=True))
        empty.find(".//*[@AutomationId='PrimaryButton']").set('Name', 'Rename')
        self.assertFalse(capture.archive_creation_controls(empty, enabled=False))

    def test_hidden_missing_or_duplicate_format_controls_are_not_archive_evidence(self):
        for mode in ('hidden', 'missing', 'duplicate'):
            with self.subTest(mode=mode):
                result = self.archive_tree()
                selector = result.find(".//*[@AutomationId='FileFormatSelector']")
                if mode == 'hidden':
                    selector.set('IsOffscreen', 'True')
                elif mode == 'missing':
                    result.getroot().remove(selector)
                else:
                    ET.SubElement(result.getroot(), 'Control', **selector.attrib)
                self.assertFalse(capture.archive_creation_controls(result, enabled=True))

    def test_invalid_requires_visible_warning_and_disabled_create(self):
        result = self.archive_tree(False)
        self.assertFalse(capture.archive_creation_controls(result, enabled=False, invalid=True))
        warning = ET.SubElement(result.getroot(), 'Window', ClassName='Popup',
                               Name='The item name specified is invalid', IsOffscreen='True')
        self.assertFalse(capture.archive_creation_controls(result, enabled=False, invalid=True))
        warning.set('IsOffscreen', 'False')
        self.assertTrue(capture.archive_creation_controls(result, enabled=False, invalid=True))
        self.assertFalse(capture.archive_creation_controls(result, enabled=False))
        result.find(".//*[@AutomationId='PrimaryButton']").set('IsEnabled', 'True')
        self.assertFalse(capture.archive_creation_controls(result, enabled=False, invalid=True))

    def test_disabled_cancel_or_editor_cannot_prove_an_interactive_dialog(self):
        for identifier in ('CloseButton', 'FileNameBox'):
            result = self.archive_tree()
            result.find(f".//*[@AutomationId='{identifier}']").set('IsEnabled', 'False')
            self.assertFalse(capture.archive_creation_controls(result, enabled=True))

    def test_tab_close_button_does_not_conflict_with_dialog_cancel(self):
        root = ET.Element('Window', Name='Files Reference')
        root.append(self.archive_tree().getroot())
        ET.SubElement(root, 'Button', AutomationId='CloseButton', Name='Close Tab',
                      IsOffscreen='False', IsEnabled='True')
        self.assertTrue(capture.archive_creation_controls(ET.ElementTree(root), enabled=True))

    def test_missing_or_multiple_archive_dialogs_are_not_accepted(self):
        result = self.archive_tree()
        result.getroot().set('Name', 'Rename')
        self.assertFalse(capture.archive_creation_controls(result, enabled=True))
        root = ET.Element('Window')
        root.extend([self.archive_tree().getroot(), self.archive_tree().getroot()])
        self.assertFalse(capture.archive_creation_controls(ET.ElementTree(root), enabled=True))

    def test_visible_warning_popup_can_be_outside_the_dialog_subtree(self):
        root = ET.Element('Window', Name='Files Reference')
        root.append(self.archive_tree(False).getroot())
        ET.SubElement(root, 'Window', ClassName='Popup', Name='The item name specified is invalid', IsOffscreen='False')
        self.assertTrue(capture.archive_creation_controls(ET.ElementTree(root), enabled=False, invalid=True))


if __name__ == '__main__':
    unittest.main()
