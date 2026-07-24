on run argv
	set brainCLI to "@BRAIN_CLI@"
	if (count of argv) > 0 then set brainCLI to item 1 of argv

	try
		set answer to display dialog "Hold Fn, speak your thought, then release Fn and press Save." default answer "" buttons {"Cancel", "Save to Brain"} default button "Save to Brain" cancel button "Cancel" with title "Brain Note"
		set noteText to text returned of answer
		if noteText is "" then
			display notification "Nothing was captured." with title "Brain Note"
			return
		end if
		set commandText to quoted form of brainCLI & " remote-note " & quoted form of noteText
		do shell script commandText
		display notification "Your thought is in the Brain inbox." with title "Saved to Brain"
	on error messageText number errorNumber
		if errorNumber is not -128 then
			display alert "Brain Note could not save" message messageText as critical
		end if
	end try
end run
