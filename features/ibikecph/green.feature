@routing @bicycle @area @green @ibikecph
Feature: Bike - prioritize green routes through green areas

	Background:
		Given the profile "green"
	
	@square	
	Scenario: Bike - Prefer ways close to parks
		Given the node map
		 |   |   | w | y |
		 | x | a | b |   |
		 |   | d | c |   |

		And the ways
		 | nodes | area | amenity |
		 | xa    |      |         |
		 | ab    |      |         |
		 | by    |      |         |
		 | xw    |      |         |
		 | wy    |      |         |
		 | abcda | yes  | park    |
		
		When I route I should get
		 | from | to | route    |
		 | x    | y  | xa,ab,by |
