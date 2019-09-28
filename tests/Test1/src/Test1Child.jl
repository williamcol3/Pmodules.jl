module Test1Child
using Pmodules

@P import ..Zibling

value = 1

sibling_value = Zibling.value

end