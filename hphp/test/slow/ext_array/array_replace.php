<?hh

function a() {
  $array1 = array(
    "color" => "red",
    2,
    4
  );
  $array2 = array(
    "a",
    "b",
    "color" => "green",
    "shape" => "trapezoid",
    4
  );
  $result = array_replace($array1, varray[$array2]);
  var_dump($result);
}

function b() {
  $array1 = array();
  $array2 = darray[1 => "data"];
  $result = array_replace($array1, varray[$array2]);
  var_dump($result);
}

function c() {
  $array1 = array();
  $array2 = darray[1 => "data"];
  $result = $array1 + $array2;
  var_dump($result);
}

function d() {
  $beginning = "foo";
  $end = darray[1 => "bar"];
  $result = array_replace((array)$beginning, varray[$end]);
  var_dump($result);
}

function e() {
  $v = 2;
  $a = darray["one" => 1];
  $b = darray["two" => $v];
  $r = array_replace($a, varray[$b]);
  var_dump($r);
}

function f() {
  $id = 100000000000022;
  $a = darray[$id => 1];
  $b = darray[$id => 2];
  $r = array_replace($a, varray[$b]);
  var_dump($r);
}

function g() {
  $a = darray[1 => 50, 5 => 60];
  $b = null;
  var_dump(array_replace($a, varray[$b]));
}


<<__EntryPoint>>
function main_array_replace() {
a();
b();
c();
d();
e();
f();
}
