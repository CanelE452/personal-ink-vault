/// Where the editor's saving is. [failed] is a save that threw: it goes on
/// as [waitingToSave] does (the next save writes again), and the save chip
/// says so (Task 13B).
enum SavingState { waitingToSave, saving, saved, failed }
