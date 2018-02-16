#pragma once

#include <string>
#include <stdbool.h>
#include "florb/src/viewport.hpp"
#include "florb/src/osmlayer.hpp"

class orb_renderviewlayer : public florb::osmlayer
{
public:
  orb_renderviewlayer();

  void draw(const florb::viewport &viewport);

private:
  float lat, lon;
  float left, right; // left and right edges of the viewable panorama; in
                     // degrees
  float pick_lat, pick_lon;
  bool have_pick;

public:

  void setlatlon( float _lat, float _lon )
  {
    lat = _lat;
    lon = _lon;
  }

  // return true if the new view is really new, and should be drawn
  bool setview( float _left, float _right );

  void set_pick( float lon, float lat );
  void unset_pick(void);
};
