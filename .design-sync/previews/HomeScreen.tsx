import { HomeScreen } from '@lyrebird/design-system'

/** The full Home app window — sidebar + content shelves + pinned PlayerBar,
 *  composed entirely from shipped design-system components. */
export const Window = () => (
	<div style={{ width: 1192, height: 752 }}>
		<HomeScreen />
	</div>
)
