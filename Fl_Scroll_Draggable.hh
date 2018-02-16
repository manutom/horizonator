#ifndef FL_SCROLL_DRAGGABLE_HH
#define FL_SCROLL_DRAGGABLE_HH

#include <FL/Fl_Scroll.H>
#include "cvFltkWidget.hh"
#include "orb_renderviewlayer.hh"
#include "florb/src/wgt_map.hpp"

class Fl_Scroll_Draggable : public Fl_Scroll
{
  int                  last_x, last_y;
  const CvFltkWidget*  render;
  orb_renderviewlayer* renderviewlayer;
  florb::wgt_map*      wgt_map;

public:

  Fl_Scroll_Draggable( int x, int y, int w, int h,
                       orb_renderviewlayer* _renderviewlayer,
                       florb::wgt_map*      _wgt_map )
    : Fl_Scroll(x,y,w,h,NULL),
      last_x(-1),
      render(NULL),
      renderviewlayer(_renderviewlayer),
      wgt_map(_wgt_map)
  {
  }

  int handle(int event);

  void draw(void);
};

#endif
