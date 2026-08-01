    Easy Flashlight Shader - True 3D Flashlight Beam with logarithmic depth-aware brightness and somewhat crappy contact shadows.

// =============================================================================
// Disclaimer
// =============================================================================

    Created by Rikufdi with AI assistance.

    This shader may be used, modified, and redistributed for non-commercial
    purposes only. Commercial use requires prior written permission.

    This software is provided "as is", without warranty of any kind.

// =============================================================================
// Disclaimer
// =============================================================================


    ****IMPORTANT****           Needs access to the depth buffer!           ****IMPORTANT****

        Use the DisplayDepth.fx in Reshade to see if you have access to the depth buffer.
        Sometimes you need to change the Global Preprocessor Definitions to Reversed or
        Upside Down. Also, in some games you need to turn off AA to get access to the
        depth buffer. Sometimes you need to manually select the depth buffer in the
        Reshade add-on and/or use the "Copy depth buffer before clear operations".

        One sneaky workaround is to use the add-on Reshade Effect Shader Toggler (REST)
        and manually pick out the shaders which have the full depth buffer and only run
        the Flashlight on those. Can be a bit tricky though.

    ****IMPORTANT****           Needs access to the depth buffer!           ****IMPORTANT****
    
    Not really an "easy" flashlight since there are way too many sliders which needs to be
    individually tuned per game to look right. Especially shadows needs tuning per game to
    be near decently looking as the hard limits of screen-space reconstruction makes them
    look really bad in most cases. Best I've managed have been to only allow shadows on
    close geometry and exaggerate with the FOV/parallax slider. Using the offsets causes
    "Ghost Shadows" and other issues so it's been best to have them at zero. Important
    to use the FOV Projection and tune shadows so that they move properly as that is what
    subjectively "anchors" them to the surface behind the occluder. The world scale was an
    attempt to have all variables and functions have that as a sort of "master" slider so
    that at least you only had one slider to tune per game but that road failed halfway
    there. The problem is that each game have different depth scales and it's been difficult
    to find a solution to that. If you don't want to do the trial and error needed for the
    shadows, just keep them turned off.

    Mostly tested with boomer-shooters such as Q1, Q2, Prodeus, Aeon: Wrath of Ruin,
    Sprawl, Dusk, and Dread Templar. All behave differently so you need to tune the
    settings per-game to get a decently working flashlight.

    I've tried a few different methods of adding light to a pixel and have ended up with
    this hybrid approach because it preserved colors best. There are essentially two light
    passes. One additive, for black and near-black pixels which also borrows color from a
    weighted average taken from the whole scene and adds a grain texture. Then, the main
    lighting pass takes over which uses a logarithmic multiplicative approach that preserves
    colors pretty well while it also manages to not blow out already bright and saturated
    pixels.

    The other methods have been:
        1.  Purely additive where you compress the whole range towards full brightness.
            Works well in lighting up black and dark pixels but got very washed out colors
            even with tries to preserve color saturation.

        2.  Convert the rgb channels into negative log space but clamping black pixels to a
            minimum (0.003) before converting. I think this will eventually beat this hybrid
            approach but have had problems implementing it so far.

        3.  Some variants of the additive above to try and preserve colors but ultimately
            didn't work out.

    Vibe-coded by many different AIs so I have no idea if everything is a mess or not as I
    have limited coding experience myself but have tried to keep it modular. The
    EasyFlashlight.fx is supposed to be more like a recipe of what to do and when and then
    call the helper library at the appropriate step.

    Don't forget the companion file Flashlight.fxh as that contains most of the functions
    and helpers. Tried to keep it modular that way.
