using System.Text;

using CrestCore.Application;
using CrestCore.Contracts;
using CrestCore.Domain;

using Xunit;

namespace CrestCore.Tests;

/// Shortcut choices are device state: the device store keeps them beside the
/// session, carried once from the document an installed release kept, and a
/// change that would take another command's keys waits for the person to
/// confirm it.
public sealed partial class BrowserContractsTests {
    /// One stored row of `device_shortcut`, spelled exactly as the store holds it.
    private sealed record StoredShortcutRow(string Command, string? Key, long Special, long Modifiers);

    private static List<StoredShortcutRow> StoredShortcutRows(string file) {
        Assert.Equal(Sqlite.Ok, Sqlite.sqlite3_open_v2(file, out var connection, Sqlite.OpenReadOnly, null));
        try {
            Assert.Equal(Sqlite.Ok, Sqlite.sqlite3_prepare_v2(connection,
                "SELECT command, key, special, modifiers FROM device_shortcut ORDER BY command", -1, out var statement, 0));
            var rows = new List<StoredShortcutRow>();
            while (Sqlite.sqlite3_step(statement) == Sqlite.Row)
                rows.Add(new(Sqlite.ColumnText(statement, 0), Sqlite.ColumnIsNull(statement, 1) ? null : Sqlite.ColumnText(statement, 1),
                    Sqlite.sqlite3_column_int64(statement, 2), Sqlite.sqlite3_column_int64(statement, 3)));
            Sqlite.sqlite3_finalize(statement);
            return rows;
        } finally {
            Sqlite.sqlite3_close_v2(connection);
        }
    }

    private static Dictionary<ShortcutCommand, ShortcutBinding> Bindings(IReadOnlyList<Change> changes) =>
        Assert.Single(changes.OfType<ShortcutsChanged>()).Bindings.ToDictionary(binding => binding.Command);

    private static KeyCombination Typed(string character, ShortcutModifiers modifiers) => new(character, false, modifiers);

    [Fact]
    public void TheShortcutsAnInstalledReleaseKeptAreAdoptedOnceExactlyAsStored() {
        using var directory = new StorageDirectory();
        // The document as the release's encoder wrote it: a typed key, a named
        // key, a command left without keys, a command this build does not know,
        // and entries that release could not have read back.
        const string Document = """
            {"newTab":{"custom":{"_0":{"key":{"character":"é"},"modifiers":3}}},
            "previousTab":{"custom":{"_0":{"key":{"special":"f20"},"modifiers":36}}},
            "showHistory":{"unassigned":{}},
            "futureCommand":{"custom":{"_0":{"key":{"character":"q"},"modifiers":1}}},
            "findInPage":{"custom":{"_0":{"key":{"character":"ab"},"modifiers":1}}},
            "zoomIn":{"custom":{"_0":{"key":{"special":"hyper"},"modifiers":1}}},
            "zoomOut":{"removed":{}}}
            """;
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            var bindings = Bindings(app.Send(new AdoptShortcuts(Encoding.UTF8.GetBytes(Document))));
            Assert.Equal(Typed("é", ShortcutModifiers.Command | ShortcutModifiers.Option), bindings[ShortcutCommand.NewTab].Keys);
            Assert.True(bindings[ShortcutCommand.NewTab].IsCustomized);
            Assert.Equal(new KeyCombination("f20", true, (ShortcutModifiers)36), bindings[ShortcutCommand.PreviousTab].Keys);
            Assert.Null(bindings[ShortcutCommand.ShowHistory].Keys);
            Assert.Equal(Typed("f", ShortcutModifiers.Command), bindings[ShortcutCommand.FindInPage].Keys);
            Assert.False(bindings[ShortcutCommand.FindInPage].IsCustomized);

            // A later adoption carries nothing more and publishes the bindings the store holds.
            var again = app.Send(new AdoptShortcuts(Encoding.UTF8.GetBytes("""{"newWindow":{"unassigned":{}}}""")));
            Assert.Equal(bindings.Values, Assert.Single(again.OfType<ShortcutsChanged>()).Bindings);
        }

        Assert.Equal([
            new StoredShortcutRow("futureCommand", "q", 0, 1),
            new StoredShortcutRow("newTab", "é", 0, 3),
            new StoredShortcutRow("previousTab", "f20", 1, 36),
            new StoredShortcutRow("showHistory", null, 0, 0)
        ], StoredShortcutRows(directory.File));
        var (relaunched, _, _) = DeviceApp(directory);
        using var relaunchedDisposal = relaunched;
        var restored = Bindings(relaunched.Send(new AdoptShortcuts(null)));
        Assert.Equal(Typed("é", ShortcutModifiers.Command | ShortcutModifiers.Option), restored[ShortcutCommand.NewTab].Keys);
        Assert.Null(restored[ShortcutCommand.ShowHistory].Keys);
        Assert.True(Assert.Single(relaunched.Send(new AdoptShortcuts(null)).OfType<ShortcutsChanged>()).IsCustomized);
    }

    /// Earlier releases saved a Shift chord on a digit key by the symbol Shift
    /// types there, ⌘⇧@ for ⇧⌘2 on a US layout, while the catalog names the
    /// digit. Those chords name the digit once, unless another command holds
    /// it, and a later adoption on any layout changes nothing. Each command's
    /// chosen preference stays with it.
    [Fact]
    public void ShortcutsSavedWithAShiftedDigitSymbolNameTheDigitOnce() {
        using var directory = new StorageDirectory();
        var shift = ShortcutModifiers.Command | ShortcutModifiers.Shift;
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            app.Send(new AdoptShortcuts(null));
            app.Send(new AssignShortcut(ShortcutCommand.ShowHistory, Typed("@", shift)));
            app.Send(new AssignShortcut(ShortcutCommand.ShowArchive, Typed("$", shift)));
            app.Send(new AssignShortcut(ShortcutCommand.ClearSiteCookies, Typed("4", shift)));
            app.Send(new ChooseShortcutPreference(ShortcutCommand.ShowHistory, ShortcutPreference.PreferWebsite));
            var renamed = Bindings(app.Send(new AdoptShiftedDigitShortcuts([new("@", "2"), new("$", "4")])));
            Assert.Equal(Typed("2", shift), renamed[ShortcutCommand.ShowHistory].Keys);
            Assert.Equal(ShortcutPreference.PreferWebsite, renamed[ShortcutCommand.ShowHistory].Preference);
            Assert.Equal(Typed("$", shift), renamed[ShortcutCommand.ShowArchive].Keys);
            Assert.Equal(Typed("4", shift), renamed[ShortcutCommand.ClearSiteCookies].Keys);

            app.Send(new UnassignShortcut(ShortcutCommand.ClearSiteCookies));
            var again = Bindings(app.Send(new AdoptShiftedDigitShortcuts([new("$", "4")])));
            Assert.Equal(Typed("$", shift), again[ShortcutCommand.ShowArchive].Keys);
        }

        var (relaunched, _, _) = DeviceApp(directory);
        using var relaunchedDisposal = relaunched;
        relaunched.Send(new AdoptShortcuts(null));
        var restored = Bindings(relaunched.Send(new AdoptShiftedDigitShortcuts([new("$", "4")])));
        Assert.Equal(Typed("2", shift), restored[ShortcutCommand.ShowHistory].Keys);
        Assert.Equal(ShortcutPreference.PreferWebsite, restored[ShortcutCommand.ShowHistory].Preference);
        Assert.Equal(Typed("$", shift), restored[ShortcutCommand.ShowArchive].Keys);
    }

    [Fact]
    public void KeysAnotherCommandHoldsWaitForConfirmationAndEveryChangeSurvivesARelaunch() {
        using var directory = new StorageDirectory();
        var find = Typed("f", ShortcutModifiers.Command);
        var chord = Typed("u", ShortcutModifiers.Command | ShortcutModifiers.Shift);
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            app.Send(new AdoptShortcuts(null));
            // Taking a default's keys is refused, naming the command that holds them.
            Assert.Equal([ShortcutCommand.FindInPage], Assert.IsType<ShortcutInUse>(Assert.Throws<Rejected>(() =>
                app.Send(new AssignShortcut(ShortcutCommand.NewTab, find))).Rejection).Commands);
            Assert.Equal(new InvalidShortcut(Typed("t", ShortcutModifiers.None)), Assert.Throws<Rejected>(() =>
                app.Send(new AssignShortcut(ShortcutCommand.NewTab, Typed("t", ShortcutModifiers.None)))).Rejection);
            // A function key types nothing, so it makes a shortcut on its own; another special key does not.
            var f12 = new KeyCombination("f12", true, ShortcutModifiers.None);
            Assert.Equal(f12, Bindings(app.Send(new AssignShortcut(ShortcutCommand.ShowWebInspector, f12)))[ShortcutCommand.ShowWebInspector].Keys);
            Assert.Equal(new InvalidShortcut(new KeyCombination("escape", true, ShortcutModifiers.None)), Assert.Throws<Rejected>(() =>
                app.Send(new AssignShortcut(ShortcutCommand.NewTab, new KeyCombination("escape", true, ShortcutModifiers.None)))).Rejection);
            Assert.Equal(new InvalidShortcut(new KeyCombination("hyper", true, ShortcutModifiers.Command)), Assert.Throws<Rejected>(() =>
                app.Send(new ReassignShortcut(ShortcutCommand.NewTab, new KeyCombination("hyper", true, ShortcutModifiers.Command))))
                .Rejection);

            var assigned = Bindings(app.Send(new AssignShortcut(ShortcutCommand.NewTab, chord)));
            Assert.Equal(chord, assigned[ShortcutCommand.NewTab].Keys);
            Assert.Empty(app.Send(new AssignShortcut(ShortcutCommand.NewTab, chord)).OfType<ShortcutsChanged>());
            Assert.Equal([ShortcutCommand.NewTab], Assert.IsType<ShortcutInUse>(Assert.Throws<Rejected>(() =>
                app.Send(new AssignShortcut(ShortcutCommand.NewWindow, chord))).Rejection).Commands);

            // Confirming takes the keys from their holder, which is left without any.
            var reassigned = Bindings(app.Send(new ReassignShortcut(ShortcutCommand.NewWindow, chord)));
            Assert.Equal(chord, reassigned[ShortcutCommand.NewWindow].Keys);
            Assert.Null(reassigned[ShortcutCommand.NewTab].Keys);
            Assert.True(reassigned[ShortcutCommand.NewTab].IsCustomized);

            // Resetting one command restores its default and nothing else.
            var reset = Bindings(app.Send(new ResetShortcut(ShortcutCommand.NewTab)));
            Assert.Equal(Typed("t", ShortcutModifiers.Command), reset[ShortcutCommand.NewTab].Keys);
            Assert.Equal(chord, reset[ShortcutCommand.NewWindow].Keys);
            Assert.Null(Bindings(app.Send(new UnassignShortcut(ShortcutCommand.ShowHistory)))[ShortcutCommand.ShowHistory].Keys);

            // A preference is a choice of its own; a command reserved from pages keeps Crest's.
            Assert.Equal(ShortcutPreference.UseBoth, reset[ShortcutCommand.ToggleSidebar].Preference);
            var preferred = Bindings(app.Send(new ChooseShortcutPreference(ShortcutCommand.ToggleSidebar, ShortcutPreference.PreferWebsite)));
            Assert.Equal(ShortcutPreference.PreferWebsite, preferred[ShortcutCommand.ToggleSidebar].Preference);
            Assert.True(preferred[ShortcutCommand.ToggleSidebar].IsCustomized);
            Assert.Empty(app.Send(new ChooseShortcutPreference(ShortcutCommand.NewTab, ShortcutPreference.PreferWebsite))
                .OfType<ShortcutsChanged>());
            Assert.False(preferred[ShortcutCommand.NewTab].ChoosesPreference);

            // Keys a text field edits with stay the field's first, whatever the command prefers.
            var undo = Bindings(app.Send(new AssignShortcut(ShortcutCommand.ReopenClosedTab, Typed("z", ShortcutModifiers.Command))));
            Assert.Equal(ShortcutPreference.PreferWebsite, undo[ShortcutCommand.ReopenClosedTab].Preference);
            Assert.False(undo[ShortcutCommand.ReopenClosedTab].ChoosesPreference);
            Assert.True(undo[ShortcutCommand.ReopenClosedTab].YieldsToTextEditing);
        }

        var (relaunched, _, _) = DeviceApp(directory);
        using var relaunchedDisposal = relaunched;
        var restored = Bindings(relaunched.Send(new AdoptShortcuts(null)));
        Assert.Equal(chord, restored[ShortcutCommand.NewWindow].Keys);
        Assert.Null(restored[ShortcutCommand.ShowHistory].Keys);
        Assert.Equal(Typed("t", ShortcutModifiers.Command), restored[ShortcutCommand.NewTab].Keys);
        Assert.Equal(ShortcutPreference.PreferWebsite, restored[ShortcutCommand.ToggleSidebar].Preference);
        Assert.Equal(ShortcutPreference.UseBoth,
            Bindings(relaunched.Send(new ResetShortcut(ShortcutCommand.ToggleSidebar)))[ShortcutCommand.ToggleSidebar].Preference);

        // Resetting every shortcut forgets them all, on disk too.
        var cleared = Assert.Single(relaunched.Send(new ResetShortcuts()).OfType<ShortcutsChanged>());
        Assert.False(cleared.IsCustomized);
        Assert.All(cleared.Bindings, binding => Assert.False(binding.IsCustomized));
        Assert.Empty(relaunched.Send(new ResetShortcuts()).OfType<ShortcutsChanged>());
    }
    [Fact]
    public void AlternateChordsKeepPrimaryChoicesAndOnlyTheCollidingSlotIsReassigned() {
        using var directory = new StorageDirectory();
        var primary = Typed("[", ShortcutModifiers.Command | ShortcutModifiers.Shift);
        var alternate = new KeyCombination("upArrow", true, ShortcutModifiers.Command | ShortcutModifiers.Option);
        var spare = new KeyCombination("f12", true, ShortcutModifiers.None);
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            app.Send(new AdoptShortcuts(null));
            app.Send(new AssignShortcut(ShortcutCommand.PreviousTab, primary));
            var added = Bindings(app.Send(new AssignAlternateShortcut(ShortcutCommand.PreviousTab, alternate)));
            Assert.Equal(primary, added[ShortcutCommand.PreviousTab].Keys);
            Assert.Equal(alternate, added[ShortcutCommand.PreviousTab].Alternate!.Keys);
            Assert.Equal(ShortcutPreference.PreferCrest, added[ShortcutCommand.PreviousTab].Alternate!.Preference);
            Assert.False(added[ShortcutCommand.PreviousTab].Alternate!.YieldsToTextEditing);
            Assert.Empty(app.Send(new AssignAlternateShortcut(ShortcutCommand.PreviousTab, alternate)).OfType<ShortcutsChanged>());
            Assert.IsType<InvalidShortcut>(Assert.Throws<Rejected>(() => app.Send(
                new AssignAlternateShortcut(ShortcutCommand.NextTab, Typed("x", ShortcutModifiers.None)))).Rejection);
            Assert.Equal([ShortcutCommand.PreviousTab], Assert.IsType<ShortcutInUse>(Assert.Throws<Rejected>(() =>
                app.Send(new AssignShortcut(ShortcutCommand.NextTab, alternate))).Rejection).Commands);
            Assert.Equal([ShortcutCommand.PreviousTab], Assert.IsType<ShortcutInUse>(Assert.Throws<Rejected>(() =>
                app.Send(new AssignAlternateShortcut(ShortcutCommand.NextTab, primary))).Rejection).Commands);
            app.Send(new AssignAlternateShortcut(ShortcutCommand.NextTab, spare));
            var taken = Bindings(app.Send(new ReassignAlternateShortcut(ShortcutCommand.NextTab, alternate)));
            Assert.Equal(primary, taken[ShortcutCommand.PreviousTab].Keys);
            Assert.Null(taken[ShortcutCommand.PreviousTab].Alternate);
            Assert.Equal(ShortcutCommand.NextTab.DefaultShortcut(DevicePlatform.Desktop)!.Keys, taken[ShortcutCommand.NextTab].Keys);
            Assert.Equal(alternate, taken[ShortcutCommand.NextTab].Alternate!.Keys);
            // Taking the other slot leaves the alternate in place.
            app.Send(new AssignAlternateShortcut(ShortcutCommand.PreviousTab, spare));
            var movedPrimary = Bindings(app.Send(new ReassignShortcut(ShortcutCommand.ShowHistory, primary)));
            Assert.Null(movedPrimary[ShortcutCommand.PreviousTab].Keys);
            Assert.Equal(spare, movedPrimary[ShortcutCommand.PreviousTab].Alternate!.Keys);
        }
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            var restored = Bindings(app.Send(new AdoptShortcuts(null)));
            Assert.Null(restored[ShortcutCommand.PreviousTab].Keys);
            Assert.Equal(spare, restored[ShortcutCommand.PreviousTab].Alternate!.Keys);
            Assert.Equal(alternate, restored[ShortcutCommand.NextTab].Alternate!.Keys);
            var cleared = Bindings(app.Send(new ClearAlternateShortcut(ShortcutCommand.NextTab)));
            Assert.Null(cleared[ShortcutCommand.NextTab].Alternate);
            Assert.Equal(ShortcutCommand.NextTab.DefaultShortcut(DevicePlatform.Desktop)!.Keys, cleared[ShortcutCommand.NextTab].Keys);
            var reset = Bindings(app.Send(new ResetShortcut(ShortcutCommand.PreviousTab)));
            Assert.Null(reset[ShortcutCommand.PreviousTab].Alternate);
            Assert.False(reset[ShortcutCommand.PreviousTab].IsCustomized);
            app.Send(new ResetShortcuts());
        }
        var (final, _, _) = DeviceApp(directory);
        using var finalDisposal = final;
        var resetAll = Assert.Single(final.Send(new AdoptShortcuts(null)).OfType<ShortcutsChanged>());
        Assert.False(resetAll.IsCustomized);
        Assert.All(resetAll.Bindings, binding => Assert.Null(binding.Alternate));
    }

    [Fact]
    public void AddingAnAlternateTablePreservesExistingPrimaryRows() {
        using var directory = new StorageDirectory();
        var primary = Typed("[", ShortcutModifiers.Command | ShortcutModifiers.Shift);
        {
            var (app, _, _) = DeviceApp(directory);
            using var disposal = app;
            app.Send(new AdoptShortcuts(null));
            app.Send(new AssignShortcut(ShortcutCommand.PreviousTab, primary));
        }
        // Simulate the schema of a release without alternate support.
        Assert.Equal(Sqlite.Ok, Sqlite.sqlite3_open_v2(directory.File, out var connection, Sqlite.OpenReadWrite, null));
        try {
            Assert.Equal(Sqlite.Ok, Sqlite.sqlite3_exec(connection, "DROP TABLE device_shortcut_alternate", 0, 0, 0));
        } finally {
            Sqlite.sqlite3_close_v2(connection);
        }
        var (reopened, _, _) = DeviceApp(directory);
        using var reopenedDisposal = reopened;
        var restored = Bindings(reopened.Send(new AdoptShortcuts(null)));
        Assert.Equal(primary, restored[ShortcutCommand.PreviousTab].Keys);
        Assert.Null(restored[ShortcutCommand.PreviousTab].Alternate);
    }

}
