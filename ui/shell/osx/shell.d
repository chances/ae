/**
 * ae.ui.osx.shell
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Chance Snow <hello@chancesnow.me>
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.ui.shell.shell;

import ae.ui.shell.shell;
import ae.ui.app.application;
public import ae.ui.shell.events;

/// `Shell` implementation using SDL2.
final class OSXShell : Shell
{
  Application application; ///
  
  this(Application application)
  {
    this.application = application;
    
    // TODO: Init OSX resources
  }
  
  override void run()
  {
    assert(video, "Video object not set");
    if (audio) audio.start(application);

    video.errorCallback = AppCallback(&quit);
    quitting = false;
    
    while (!quitting)
    {
      // start renderer
      video.start(application);
      
      // The main purpose of this call is to allow the application
      // to react to window size changes.
      application.handleInit();
      
      // wait for renderer to stop
      video.stop();
    }
  }
}
