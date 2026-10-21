package notice

import "testing"

func TestTheTestAndTheUpdateHaveTagsOfTheirOwn(t *testing.T) {
	if TestTag == "" || UpdateTag == "" || TestTag == UpdateTag {
		t.Error("the tags must differ, or the test would replace the update")
	}
}

func TestOnlyTheTestIsShownWhenTheWindowIsInFront(t *testing.T) {
	if !ShowsInFront(TestTag) || ShowsInFront(UpdateTag) || ShowsInFront("") {
		t.Error("the update is for when the window is not in front")
	}
}
