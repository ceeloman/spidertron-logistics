# How the Spidertron Logistics Mod Has Evolved

## What Changed Since the Beginning

This document explains how the mod has grown and improved since its initial version 2.2.4 release. Instead of technical details, we'll focus on what you, the player, can actually do with the mod and how your experience has changed.

---

## Getting Started: Much Easier Now

### Then (Version 2.2.4)
- **Expensive Recipes**: You needed requester chests, storage chests, and spidertron remotes just to craft the basic components
- **Late Game Only**: Required the full "logistic-system" technology, meaning you couldn't use it until very late in the game
- **Equipment Required**: Every spidertron needed a special "logistic controller" equipment installed in its grid to participate in logistics

### Now (Version 3.2.0)
- **Simple Materials**: Just steel plates, electronic circuits, and advanced circuits - basic materials you have early on
- **Early Access**: Dynamically unlocks after the first Spider vehicle (and advanced ciruits), whether thats the vanilla Spidertron, or a modded one
- **No Equipment Needed**: Just open your spidertron's inventory and flip a toggle switch - no equipment required!

---

## Controlling Your Spiders: From Equipment to Toggle

### Then
The only way to make a spidertron participate in logistics was to install the logistic controller equipment. If you removed it, the spider stopped working. You couldn't easily turn logistics on or off without swapping equipment.

### Now
Open any spidertron's inventory and you'll see a toggle button. Click it to activate or deactivate that spider's participation in the logistics network. It's instant, easy, and you can control each spider individually. No more equipment juggling!

### Soon
Manage logistics through either the Vehicle Control Center dedicated Spider Logistics GUI, or maybe the mod will have its own GUI.

---

## Requesting Items: One at a Time vs. Multiple Items

### Then
Each requester chest could only request **one type of item** at a time. Need iron plates and copper plates? You needed two separate requester chests.

### Now
Each requester chest can request **multiple different items** simultaneously. Open the chest, click "Add Item", choose what you need and how many, then add another item, and another. One chest can handle all your needs for that location.

The GUI is also much better - instead of typing numbers in a text field, you get a nice slider to set quantities, and you can see all your requests at once.

---

## Smart Pathfinding: A little bit more intelligent

### Then
Spiders would take the most direct route possible, which often meant:
- Trying to walk through water (and getting stuck)
- Walking straight through enemy nests (and getting destroyed)
- Getting stuck and never completing deliveries

### Now
Spiders are much smarter about navigation:
- **Water Detection**: They detect water crossings and find the best way around, or if they can traverse on water (Space Spidertron), they'll take the shortest path
- **Cliff Awareness**: Small spiders that can't climb cliffs will automatically route around them
- **Enemy Avoidance**: Spiders will detour around enemy nests to avoid combat (They aim for about 80 tiles around nests)
- **Stuck Detection**: If a spider hasn't moved in 10 seconds, it automatically tries a new path
- **Waypoint System**: For long journeys, spiders use waypoints to navigate efficiently
- **Waypoint Smoothing**: Spiders now travel along smoother, more direct routes by minimizing or removing unnecessary waypoints whenever possible. Instead of strictly following a series of points (which could look awkward or zig-zaggy), the new system makes journeys appear much more natural and fluid, leading to quicker, smarter-looking movement across the map.

---

## Network Coverage: Unlimited Range

### Then
Everything had to be within the Spidertron Logistic Beacons range. If your requester chest was too far from your provider chest, they couldn't connect. You had to many Spidertron Logistic Beacons to cover even a small area.

### Now
**Unlimited range!** Beacons now use their own radar network to send signals across the surface, they can connect to chests anywhere. You can have a provider chest on one side of the map and a requester chest on the other side, and spiders will handle the delivery. The network is surface-wide, not range-limited.

### Ceelo's comments:
Technically one beacon can cover the entire surface, behind the scenes theres some code that tracks the pick ups and deliveries per chest, each chest provider and requester chest is assigned to the closest beacon. Spiders will wait near beacons that have higher provider numbers. If you have 10 Spiders, and 80% of your picks come from this area, 8 of the spiders will aim to wait near that beacon, the other 2 will delegate themselves to the next most popular option. A GUI for insights into this will come later.

---

## Multi-Stop Deliveries: Efficiency Improvements

### Then
Each spider would make one trip: pick up one item type from one provider, deliver to one requester, then return to a beacon. If you needed multiple items, multiple spiders would each make separate trips.

### Now
Spiders can handle **multi-item and multi-requester deliveries** more efficiently. A single spider might pick up iron plates, deliver some to requester A, then deliver the rest to requester B, all in one journey. This means fewer spiders needed and faster overall delivery times.

**Note**: Currently, multi-route assignment works in theory but has limitations. When a job is triggered, the first available spider is immediately assigned before other requests can be queued together. There's no buffer or delay system to batch requests that might be on the same route.

### Ceelo's comments:
In theory and practice scenarios this works, in game, a job is triggered, the first spider is assigned the job before another request can be given to it. Maybe we apply a longer wait for a job, or use the job delays as a time to wait for other requests. Maybe we can assign a spider candidate, and then that spider can wait for the job to start, in the meantime we can wait for other jobs to appear, and if they are on route then add them to the queue. if not on route, or its desparate and other spiders are available, assign another spider. if theres a desperate request then assign the pending spider.  

---

## Automatic Item Management

### Then
If a spider picked up items it didn't need (maybe from a failed delivery or leftover inventory), it would just carry them around forever, taking up space.

### Now
Spiders automatically dump excess items into storage chests. If they have items that aren't needed for any active requests, they'll find a storage chest and drop them off. You can also manually trigger item dumping with a button in the GUI via the bin button, or to reset the spider and to path to best beacon, just toggle the spider on and off again via its gui.

---

## Better Visual Feedback

### Then
You'd get basic warning icons if something was wrong (like no network connection), but not much else. It was hard to tell what was happening.

### Now
- Clear visual indicators when spiders are picking up or dropping off items
- Error messages appear directly on entities when pathfinding fails
- Better status indicators so you know what your spiders are doing
- Icons show when items are being withdrawn or deposited

---

## Compatibility: Works with More Mods

### Then
The mod had hardcoded support for specific spider mods (like Insectitron or Spidertrontiers). If you used a different spider mod, it might not work properly.

### Now
The mod automatically detects whatever spider vehicle technology you have, regardless of which mod provides it. It works with any spider mod, making it much more flexible and compatible.

I havent checked this with mods that introduce other spider tiers. Except my own very early small Spiderbots MK2 from Ceelos Vehicle Tweaks. And Space Spidertron, I will test with Spidertron Patrols Spiderling.

---

## Blueprint Support

### Then
You could blueprint requester chests, but the request settings wouldn't save. You had to manually configure each chest after placing from a blueprint.

### Now
When you blueprint a requester chest with multiple item requests configured, all those requests are saved in the blueprint. Place the blueprint and the chests are already configured exactly as you set them up.

---

## What Stayed the Same (The Core Concept)

The fundamental idea hasn't changed: you place requester chests where you need items, provider chests where you have items, and logistic beacons to connect them. Spidertrons automatically pick up items from providers and deliver them to requesters. That core gameplay loop remains the same - we just made everything work better, faster, and easier.

---

## Removed Features

### Robot Logistic Chest Support (Removed in Version 3.3.0)

**What Was Removed**: Support for using vanilla robot logistic chests (storage-chest, active-provider-chest, passive-provider-chest) as providers in the spidertron logistics network.

**Why It Was Removed**: This feature caused significant performance issues. The system was scanning and caching all robot chests across the entire surface, which became problematic in large bases. The performance cost outweighed the convenience benefit.

**What This Means**: You can no longer use vanilla storage chests, active provider chests, or passive provider chests as sources for spidertron logistics. You must use the custom spidertron logistics provider chests instead.

**Future Plans**: Robot chest support may be re-added in the future with an optimized implementation that uses chunk-based scanning and only processes chests that contain requested items. See the "Future Plans" section for more details.

---

## Summary: What This Means for You

**Easier to Get Started**: Cheaper recipes and earlier technology unlock mean you can start using spidertron logistics much sooner in your playthrough.

**More Flexible**: Multi-item requests, unlimited range, and better pathfinding mean you can build more complex and spread-out logistics networks.

**More Reliable**: Smart pathfinding and stuck detection mean your spiders actually complete their deliveries instead of getting stuck or destroyed.

**Easier to Control**: Toggle switches instead of equipment, better GUI, and manual controls give you more direct control over your logistics network.

**Better Performance**: Under the hood improvements mean the mod runs smoother, especially with many spiders active.

The mod has grown from a basic "spiders deliver items" system into a sophisticated, intelligent logistics network that's both more powerful and easier to use.

---

## Future Plans / To Think About

This section documents ideas and potential improvements that are being considered but not yet implemented.

### Improved Multi-Route Assignment with Buffering

**Current Limitation**: When a request comes in, a spider is immediately assigned before other requests can be batched together. This prevents optimal route planning.

**Potential Solution**: Implement a buffer/delay system for job assignment:
- When a request appears, assign a spider as a "candidate" but don't immediately send it
- During a short delay window, wait for additional requests to appear
- If new requests are on the same route, add them to the spider's queue
- If requests are not on route, or if the request is desperate and other spiders are available, assign a different spider
- If a desperate request appears while a spider is pending, immediately assign the pending spider

This would allow spiders to handle multiple deliveries more efficiently by batching requests that are geographically close or on the same path.

### Robot Logistic Chest Integration

**Previous Implementation**: In version 3.0.0, robot logistic chests (storage-chest, active-provider-chest, passive-provider-chest) were added as providers, allowing spiders to pick up items from regular robot chests.

**Current Status**: This feature was removed in version 3.3.0 due to performance concerns. The system was scanning and caching all robot chests across the entire surface, which caused significant performance issues, especially in large bases.

**Future Implementation**: Robot chest support may be re-added with optimized implementation:
- Use chunk-based scanning instead of full surface scans
- Only scan chunks where requesters exist
- Process robot chests in batches (N chests per cycle)
- Only cache robot chests that contain requested items
- Update cache when robot chests are built/destroyed
- This would allow robots to fill the chests while spiders handle long-distance delivery

**Alternative Idea**: Make the spidertron logistics chests also function as robot logistic chests, allowing regular logistic robots to interact with them.

**Considerations**:
- This could be game-breaking since buffer chests are locked behind later-game technology
- Need to consider balance and progression
- Circuit control might interfere if buffer chests can have circuit-set filters

**Potential Approach**: 
- Keep the 1x1 chests as regular storage chests (robot-accessible)
- Add a 2x2 buffer chest variant that functions as both spidertron logistics and robot buffer chests

### GUI Improvements

**Current State**: The GUI works but isn't quite satisfactory yet.

**Planned Improvements**:
- Better integration with Vehicle Control Center mod (dedicated Spider Logistics GUI)
- Or create the mod's own standalone GUI for managing spider logistics
- Improve the requester chest GUI for better usability
- Add circuit network control for scripted requests
- Consider how circuit control interacts with buffer chest filters (if implemented)

### Beacon Analytics GUI

**Planned Feature**: A GUI to show insights into beacon activity:
- Pickup and delivery statistics per beacon
- Spider distribution across beacons
- Traffic patterns and popular pickup locations
- This would help players optimize their logistics network layout

### Additional Compatibility Testing

**To Test**:
- Mods that introduce other spider tiers (beyond the basic spider vehicle)
- Spidertron Patrols mod (Spiderling)
- Other spider vehicle mods to ensure dynamic detection works properly

### Circuit Network Control for Requests

**Idea**: Allow circuit networks to control requester chest requests programmatically.

**Considerations**:
- Need to ensure this doesn't interfere with buffer chest filter functionality (if buffer chests are added)
- Should work alongside manual GUI configuration
- Need to handle edge cases where both circuit and manual control are active
