#pragma once

#include "util/types.hpp"

class Camera {
  quat orientation_; // Quaternion representing rotation
  vec3 position_;    // Camera position in world space

  float fovY_;       // Vertical field of view in radians
  float aspect_;     // Aspect ratio (width / height)
  float nearPlane_;  // Near clipping plane
  float farPlane_;   // Far clipping plane

  // Cached matrices
  mutable mat4 viewMatrix_;
  mutable bool viewMatrixUpdated_ = false;

  mat4 projectionMatrix_;

  void updateProjectionMatrix() {
    projectionMatrix_ = glm::perspective(fovY_, aspect_, nearPlane_, farPlane_);
    projectionMatrix_[1][1] *= -1; // Vulkan NDC Y is inverted
  }
public:
  Camera()
    : orientation_(1, 0, 0, 0)
    , position_(0, 0, 10.0f)
    , fovY_(glm::radians(45.0f))
    , aspect_(4.0f / 3.0f)
    , nearPlane_(0.1f)
    , farPlane_(10000.0f)
  {
    getViewMatrix();
    updateProjectionMatrix();
  }

  vec3 position() const {
    return position_;
  }

  vec3 forward() const {
    return orientation_ * vec3(0, 0, -1);
  }

  vec3 up() const {
    return orientation_ * vec3(0, 1, 0);
  }

  vec3 right() const {
    return orientation_ * vec3(1, 0, 0);
  }

  void setPosition(const vec3& position) {
    position_ = position;
    viewMatrixUpdated_ = false;
  }

  void setOrientation(const quat& orientation) {
    orientation_ = glm::normalize(orientation);
    viewMatrixUpdated_ = false;
  }

  void moveForward(float delta) {
    position_ += forward() * delta;
    viewMatrixUpdated_ = false;
  }

  void moveRight(float delta) {
    position_ += right() * delta;
    viewMatrixUpdated_ = false;
  }

  void moveUp(float delta) {
    position_ += up() * delta;
    viewMatrixUpdated_ = false;
  }

  // axis must be normalized
  void rotate(float angleRad, vec3 axis) {
    quat q = glm::angleAxis(angleRad, axis);
    orientation_ = glm::normalize(q * orientation_);
    viewMatrixUpdated_ = false;
  }

  void rotateYaw(float angleRad) {
    rotate(angleRad, vec3(0, 1, 0));
  }

  void rotatePitch(float angleRad) {
    rotate(angleRad, right());
  }

  void rotateRoll(float angleRad) {
    rotate(angleRad, forward());
  }

  const mat4& getViewMatrix() const noexcept {
    if (!viewMatrixUpdated_) {
      mat4 rotation = mat4_cast(glm::conjugate(orientation_));
      mat4 translation = glm::translate(mat4(1.0f), -position_);
      viewMatrix_ = rotation * translation;
      viewMatrixUpdated_ = true;
    }
    return viewMatrix_;
  }

  // Projection matrix

  void setPerspective(float fovYRad, float aspect, float nearPlane, float farPlane) {
    fovY_ = fovYRad;
    aspect_ = aspect;
    nearPlane_ = nearPlane;
    farPlane_ = farPlane;
    updateProjectionMatrix();
  }

  void setAspectRatio(float aspect) {
    aspect_ = aspect;
    updateProjectionMatrix();
  }

  void setFOV(float fovYRad) {
    fovY_ = fovYRad;
    updateProjectionMatrix();
  }

  void setClippingPlanes(float nearPlane, float farPlane) {
    nearPlane_ = nearPlane;
    farPlane_ = farPlane;
    updateProjectionMatrix();
  }

  const mat4& getProjectionMatrix() const noexcept {
    return projectionMatrix_;
  }
};
